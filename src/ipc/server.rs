//! Daemon-side IPC server.
//!
//! Accepts Unix socket connections, performs the `Hello`/`Welcome` handshake,
//! fans out broadcast `ServerMsg`s to subscribed clients, **and** handles
//! incoming PTY commands from each client (Phase 5b).
//!
//! ## Architecture
//!
//! Each connected client runs in its own `handle_client` task.  The task
//! maintains a three-way `tokio::select!`:
//!
//! 1. **Broadcast** — activity / Mother events → write to socket.
//! 2. **Targeted** — PTY output / control messages aimed at this client.
//! 3. **Socket reads** — incoming `ClientMsg` (PTY commands).
//!
//! The targeted channel is registered with [`PtyManager::client_sender_registry`]
//! on connect and removed on disconnect.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::Result;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpListener, UnixListener};
use tokio::sync::{broadcast, mpsc};
use tracing::{debug, info, warn};
use uuid::Uuid;

use super::{
    codec::{read_frame, write_frame},
    decisions::{AnswerOutcome, DecisionRegistry},
    protocol::{ClientMsg, MotherActionKind, ServerMsg, SessionAction, Topic, MIN_CLIENT_VERSION, PROTOCOL_VERSION},
    pty_manager::PtyManager,
    session_manager::SessionManager,
};

/// Handle to the running IPC server.  Drop to shut down.
pub struct Server {
    socket_path: PathBuf,
    pub tx: broadcast::Sender<ServerMsg>,
}

impl Server {
    /// Bind a `UnixListener` at `socket_path`.
    ///
    /// `pty_mgr` and `session_mgr` are shared with every client handler for PTY
    /// and persistent-session command routing respectively.
    ///
    /// `perri_state_dir` is forwarded to the `PerriAction` handler so the
    /// `"approve"` arm can write the Phase 1 approval signal (approvals.jsonl +
    /// queue.dirty) for instant queue suppression.
    ///
    /// `decisions` is the shared decision-modal registry (W6) — also handed to
    /// `DaemonMcpBackend` so `nostromo.ask_decision` and this IPC layer share
    /// one source of truth for outstanding requests and `Topic::Decision`
    /// subscribers.
    pub fn bind(
        socket_path: &Path,
        pty_mgr: Arc<Mutex<PtyManager>>,
        session_mgr: Arc<Mutex<SessionManager>>,
        perri_state_dir: PathBuf,
        decisions: Arc<Mutex<DecisionRegistry>>,
    ) -> Result<Self> {
        // Remove stale socket file so bind doesn't fail.
        let _ = std::fs::remove_file(socket_path);

        if let Some(parent) = socket_path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let listener = UnixListener::bind(socket_path)?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600))?;
        }

        let (tx, _) = broadcast::channel::<ServerMsg>(512);
        let tx_clone = tx.clone();
        let path = socket_path.to_path_buf();

        tokio::spawn(async move {
            if let Err(e) = accept_loop(listener, tx_clone, pty_mgr, session_mgr, perri_state_dir, decisions).await {
                warn!("IPC accept loop exited: {e:#}");
            }
        });

        info!(socket = %socket_path.display(), "IPC server listening");

        Ok(Self {
            socket_path: path,
            tx,
        })
    }

    /// Broadcast a message to all connected, subscribed clients.
    pub fn broadcast(&self, msg: ServerMsg) {
        let _ = self.tx.send(msg);
    }

    /// Attach a TCP listener that shares the same broadcast channel and PTY/
    /// session managers as the Unix socket listener.
    ///
    /// Both transports run the identical `handle_client` handshake loop, so iOS
    /// (and any other TCP peer) behaves exactly like the macOS TUI client.
    ///
    /// `perri_state_dir` and `decisions` are forwarded identically to
    /// [`Server::bind`].
    pub fn bind_tcp(
        &self,
        listener: TcpListener,
        pty_mgr: Arc<Mutex<PtyManager>>,
        session_mgr: Arc<Mutex<SessionManager>>,
        perri_state_dir: PathBuf,
        decisions: Arc<Mutex<DecisionRegistry>>,
    ) {
        let tx = self.tx.clone();
        tokio::spawn(async move {
            if let Err(e) = accept_loop_tcp(listener, tx, pty_mgr, session_mgr, perri_state_dir, decisions).await {
                warn!("TCP IPC accept loop exited: {e:#}");
            }
        });
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

// ── accept loops ──────────────────────────────────────────────────────────────

async fn accept_loop(
    listener: UnixListener,
    tx: broadcast::Sender<ServerMsg>,
    pty_mgr: Arc<Mutex<PtyManager>>,
    session_mgr: Arc<Mutex<SessionManager>>,
    perri_state_dir: PathBuf,
    decisions: Arc<Mutex<DecisionRegistry>>,
) -> Result<()> {
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let rx = tx.subscribe();
                let pty_mgr = Arc::clone(&pty_mgr);
                let session_mgr = Arc::clone(&session_mgr);
                let broadcast_tx = tx.clone();
                let psd = perri_state_dir.clone();
                let decisions = Arc::clone(&decisions);
                tokio::spawn(async move {
                    if let Err(e) = handle_client(stream, rx, broadcast_tx, pty_mgr, session_mgr, psd, decisions).await {
                        debug!("client disconnected: {e:#}");
                    }
                });
            }
            Err(e) => {
                warn!("accept error: {e}");
            }
        }
    }
}

async fn accept_loop_tcp(
    listener: TcpListener,
    tx: broadcast::Sender<ServerMsg>,
    pty_mgr: Arc<Mutex<PtyManager>>,
    session_mgr: Arc<Mutex<SessionManager>>,
    perri_state_dir: PathBuf,
    decisions: Arc<Mutex<DecisionRegistry>>,
) -> Result<()> {
    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                info!(%addr, "TCP IPC client connected");
                let rx = tx.subscribe();
                let pty_mgr = Arc::clone(&pty_mgr);
                let session_mgr = Arc::clone(&session_mgr);
                let broadcast_tx = tx.clone();
                let psd = perri_state_dir.clone();
                let decisions = Arc::clone(&decisions);
                tokio::spawn(async move {
                    if let Err(e) = handle_client(stream, rx, broadcast_tx, pty_mgr, session_mgr, psd, decisions).await {
                        debug!(%addr, "TCP client disconnected: {e:#}");
                    }
                });
            }
            Err(e) => {
                warn!("TCP accept error: {e}");
            }
        }
    }
}

// ── per-client task ───────────────────────────────────────────────────────────

/// Handle a single connected client over any async transport (Unix socket, TCP, …).
///
/// The caller provides a stream that implements both [`AsyncRead`] and
/// [`AsyncWrite`].  `tokio::io::split` provides transport-agnostic halves
/// whose `ReadHalf`/`WriteHalf` are always `Unpin`, so the handshake and
/// the `select!` loop below need no stream-specific code.
async fn handle_client<S>(
    stream: S,
    mut broadcast_rx: broadcast::Receiver<ServerMsg>,
    broadcast_tx: broadcast::Sender<ServerMsg>,
    pty_mgr: Arc<Mutex<PtyManager>>,
    session_mgr: Arc<Mutex<SessionManager>>,
    perri_state_dir: PathBuf,
    decisions: Arc<Mutex<DecisionRegistry>>,
) -> Result<()>
where
    S: AsyncRead + AsyncWrite,
{
    let (mut reader, mut writer) = tokio::io::split(stream);

    // ── Handshake ─────────────────────────────────────────────────────────────

    let hello_bytes = read_frame(&mut reader).await?;
    let hello: ClientMsg = serde_json::from_slice(&hello_bytes)?;

    // `claimed_id` is what the client sent; used only for log context.
    // `conn_key` is a server-minted UUID used as the registry routing key so
    // that a malicious client cannot hijack another connection's targeted
    // channel by sending a pre-known client_id.
    let (claimed_id, conn_key) = match hello {
        ClientMsg::Hello {
            ref client_id,
            protocol_version,
        } => {
            if protocol_version < MIN_CLIENT_VERSION {
                let err = ServerMsg::Error {
                    message: format!(
                        "protocol version {protocol_version} < required {MIN_CLIENT_VERSION}"
                    ),
                };
                let _ = write_frame(&mut writer, &serde_json::to_vec(&err)?).await;
                anyhow::bail!(
                    "client version {protocol_version} too old (need {MIN_CLIENT_VERSION}+)"
                );
            }
            (client_id.clone(), Uuid::new_v4().to_string())
        }
        other => {
            let err = ServerMsg::Error {
                message: format!("expected Hello, got {other:?}"),
            };
            let _ = write_frame(&mut writer, &serde_json::to_vec(&err)?).await;
            anyhow::bail!("unexpected first message: {other:?}");
        }
    };

    let welcome = ServerMsg::Welcome {
        protocol_version: PROTOCOL_VERSION,
        daemon_pid: std::process::id(),
    };
    write_frame(&mut writer, &serde_json::to_vec(&welcome)?).await?;
    debug!(claimed_id, conn_key, "client welcomed");

    // ── Subscribe ─────────────────────────────────────────────────────────────

    let sub_bytes = read_frame(&mut reader).await?;
    let sub: ClientMsg = serde_json::from_slice(&sub_bytes)?;

    let topics: Vec<Topic> = match sub {
        ClientMsg::Subscribe { topics } => topics,
        ClientMsg::Ping => {
            write_frame(&mut writer, &serde_json::to_vec(&ServerMsg::Pong)?).await?;
            vec![]
        }
        other => {
            anyhow::bail!("expected Subscribe, got {other:?}");
        }
    };

    info!(claimed_id, conn_key, ?topics, "client subscribed");

    // ── Decision-modal subscriber accounting (W6) ─────────────────────────────
    // An empty `topics` list means "everything" (see `message_matches_topics`),
    // so it counts as subscribed to `Topic::Decision` too. Being subscribed is
    // also how `nostromo.ask_decision` knows an operator exists at all — this
    // is the only place that fact is recorded.
    let is_decision_subscriber = topics.is_empty() || topics.contains(&Topic::Decision);
    if is_decision_subscriber {
        decisions.lock().unwrap().add_subscriber(&conn_key);
    }

    // ── Register per-client targeted channel ──────────────────────────────────
    // Use `conn_key` (server-minted UUID) as the registry key — not the
    // client-supplied `claimed_id` — so no remote peer can impersonate an
    // existing connection by guessing or replaying another client's id.

    let (targeted_tx, mut targeted_rx) = mpsc::unbounded_channel::<ServerMsg>();
    {
        let mgr = pty_mgr.lock().unwrap();
        let registry = mgr.client_sender_registry();
        let mut senders = registry.lock().unwrap();
        senders.insert(conn_key.clone(), targeted_tx.clone());
    }
    {
        // The session manager keeps its own client-sender registry for session
        // attach fan-out.
        let mgr = session_mgr.lock().unwrap();
        let registry = mgr.client_sender_registry();
        let mut senders = registry.lock().unwrap();
        senders.insert(conn_key.clone(), targeted_tx.clone());
    }

    // ── Layout replay — push existing pane trees to newly subscribed client ──
    // A freshly connected or reconnected client would otherwise see empty panes
    // until the agent next sends a structural mutation. Replay one FocusLayout
    // per registered focus so the client starts with a complete picture.
    // `focused_pane` is omitted (None) — the registry does not persist it;
    // the agent's next `set_pane_focus` call will re-establish it.
    if topics.contains(&Topic::Layout) {
        let mut snapshots: Vec<ServerMsg> = {
            let mgr = session_mgr.lock().unwrap();
            if let Some(reg) = mgr.pane_registry() {
                reg.lock().unwrap()
                    .all_layouts()
                    .into_iter()
                    .map(|(tag, tree, focused)| ServerMsg::FocusLayout {
                        tag,
                        tree,
                        focused_pane: focused,
                    })
                    .collect()
            } else {
                vec![]
            }
        };
        // Live pane content for every bound pane, so a (re)connecting client
        // is never left staring at an assembled-but-empty workspace (D8).
        // Appended after the FocusLayout replay so structure always precedes
        // content on the wire, matching every other broadcast in this protocol.
        {
            let mgr = session_mgr.lock().unwrap();
            if let Some(provider) = mgr.pane_content_provider() {
                snapshots.extend(provider.bound_pane_contents());
            }
        }
        for msg in snapshots {
            let bytes = serde_json::to_vec(&msg).unwrap_or_default();
            if !bytes.is_empty() {
                let _ = write_frame(&mut writer, &bytes).await;
            }
        }
    }

    // ── Main loop (broadcast + targeted + client reads) ───────────────────────

    let result: Result<()> = loop {
        tokio::select! {
            // Broadcast events (activity, Mother, etc.)
            bcast = broadcast_rx.recv() => {
                match bcast {
                    Ok(msg) => {
                        if !message_matches_topics(&msg, &topics) {
                            continue;
                        }
                        let bytes = match serde_json::to_vec(&msg) {
                            Ok(b) => b,
                            Err(e) => { warn!("serialise error: {e}"); continue; }
                        };
                        if write_frame(&mut writer, &bytes).await.is_err() {
                            break Ok(());
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!(conn_key, "client lagged {n} broadcast messages");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        break Ok(());
                    }
                }
            }

            // Targeted messages (PTY output, PtySpawned, PtyAttached, etc.)
            Some(msg) = targeted_rx.recv() => {
                let bytes = match serde_json::to_vec(&msg) {
                    Ok(b) => b,
                    Err(e) => { warn!("serialise targeted msg: {e}"); continue; }
                };
                if write_frame(&mut writer, &bytes).await.is_err() {
                    break Ok(());
                }
            }

            // Commands from client
            frame = read_frame(&mut reader) => {
                match frame {
                    Ok(bytes) => {
                        let msg: ClientMsg = match serde_json::from_slice(&bytes) {
                            Ok(m) => m,
                            Err(e) => {
                                warn!(claimed_id, conn_key, "bad ClientMsg: {e}");
                                continue;
                            }
                        };
                        handle_client_msg(msg, &conn_key, &pty_mgr, &session_mgr, &targeted_tx, &broadcast_tx, &perri_state_dir, &decisions);
                    }
                    Err(_) => {
                        // Client disconnected.
                        break Ok(());
                    }
                }
            }
        }
    };

    // ── Cleanup ───────────────────────────────────────────────────────────────

    debug!(
        claimed_id,
        conn_key,
        "client handler exiting; detaching PTYs + sessions"
    );
    {
        let mut mgr = pty_mgr.lock().unwrap();
        mgr.on_client_disconnect(&conn_key);
    }
    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.on_client_disconnect(&conn_key);
    }
    if is_decision_subscriber {
        decisions.lock().unwrap().remove_subscriber(&conn_key);
    }

    result
}

// ── PTY command dispatch ──────────────────────────────────────────────────────

/// `conn_key` is the server-minted UUID for this connection (not the
/// client-supplied `client_id` from the Hello frame).
fn handle_client_msg(
    msg: ClientMsg,
    conn_key: &str,
    pty_mgr: &Arc<Mutex<PtyManager>>,
    session_mgr: &Arc<Mutex<SessionManager>>,
    targeted_tx: &mpsc::UnboundedSender<ServerMsg>,
    broadcast_tx: &broadcast::Sender<ServerMsg>,
    perri_state_dir: &Path,
    decisions: &Arc<Mutex<DecisionRegistry>>,
) {
    match msg {
        ClientMsg::Ping => {
            let _ = targeted_tx.send(ServerMsg::Pong);
        }

        ClientMsg::PtySpawn {
            pty_id,
            cmd,
            args,
            cols,
            rows,
            cwd,
            client_tag,
        } => {
            let result = {
                let mut mgr = pty_mgr.lock().unwrap();
                mgr.spawn_pty(pty_id, &cmd, &args, cols, rows, cwd, client_tag)
            };
            match result {
                Ok((id, nostromo_pty_id, nostromo_session_id)) => {
                    let _ = targeted_tx.send(ServerMsg::PtySpawned { pty_id: id.clone() });
                    // Send PtyIdentity follow-up so the TUI can register the PTY
                    // with McpSharedState.  Sent as a separate message to avoid a
                    // protocol-version bump.
                    let _ = targeted_tx.send(ServerMsg::PtyIdentity {
                        pty_id: id,
                        nostromo_pty_id,
                        nostromo_session_id,
                    });
                }
                Err(e) => {
                    warn!(conn_key, cmd, "PtySpawn failed: {e:#}");
                    let _ = targeted_tx.send(ServerMsg::Error {
                        message: format!("PtySpawn failed: {e}"),
                    });
                }
            }
        }

        ClientMsg::PtyAttach { pty_id } => {
            let result = {
                let mut mgr = pty_mgr.lock().unwrap();
                mgr.attach(&pty_id, conn_key)
            };
            if let Err(e) = result {
                let _ = targeted_tx.send(ServerMsg::Error {
                    message: format!("PtyAttach failed: {e}"),
                });
            }
        }

        ClientMsg::PtyDetach { pty_id } => {
            let mut mgr = pty_mgr.lock().unwrap();
            mgr.detach(&pty_id, conn_key);
        }

        ClientMsg::PtyInput { pty_id, bytes } => {
            let mut mgr = pty_mgr.lock().unwrap();
            if let Err(e) = mgr.send_input(&pty_id, &bytes) {
                warn!(conn_key, "PtyInput error: {e}");
            }
        }

        ClientMsg::PtyResize { pty_id, cols, rows } => {
            let mut mgr = pty_mgr.lock().unwrap();
            if let Err(e) = mgr.resize_pty(&pty_id, cols, rows) {
                warn!(conn_key, "PtyResize error: {e}");
            }
        }

        ClientMsg::PtyKill { pty_id } => {
            let mut mgr = pty_mgr.lock().unwrap();
            mgr.kill_pty(&pty_id);
        }

        ClientMsg::PtyList => {
            let mgr = pty_mgr.lock().unwrap();
            let ptys = mgr.list_with_ids();
            let _ = targeted_tx.send(ServerMsg::PtyListResp { ptys });
        }

        // ── persistent session commands (protocol v3) ─────────────────────────
        ClientMsg::SessionSpawn {
            tag,
            agent_name,
            view_name,
            cwd,
            session_id,
            remote_control,
        } => {
            let result = {
                let mut mgr = session_mgr.lock().unwrap();
                mgr.spawn_session(
                    tag.clone(),
                    agent_name,
                    view_name,
                    cwd,
                    session_id,
                    remote_control,
                )
            };
            match result {
                Ok(session_id) => {
                    let _ = targeted_tx.send(ServerMsg::SessionSpawned { tag, session_id });
                }
                Err(e) => {
                    warn!(conn_key, %tag, "SessionSpawn failed: {e:#}");
                    let _ = targeted_tx.send(ServerMsg::Error {
                        message: format!("SessionSpawn failed: {e}"),
                    });
                }
            }
        }

        ClientMsg::SessionAttach { tag } => {
            let result = {
                let mut mgr = session_mgr.lock().unwrap();
                mgr.attach(&tag, conn_key)
            };
            if let Err(e) = result {
                let _ = targeted_tx.send(ServerMsg::Error {
                    message: format!("SessionAttach failed: {e}"),
                });
            }
        }

        ClientMsg::SessionDetach { tag } => {
            let mut mgr = session_mgr.lock().unwrap();
            mgr.detach(&tag, conn_key);
        }

        ClientMsg::SessionSend { tag, text, images } => {
            let mut mgr = session_mgr.lock().unwrap();
            if let Err(e) = mgr.send_user_message(&tag, &text, &images) {
                warn!(conn_key, %tag, "SessionSend error: {e}");
                let _ = targeted_tx.send(ServerMsg::Error {
                    message: format!("SessionSend failed: {e}"),
                });
            }
        }

        ClientMsg::SessionControl { tag, action } => {
            let mut mgr = session_mgr.lock().unwrap();
            match action {
                SessionAction::Stop => mgr.stop(&tag),
                SessionAction::Restart => {
                    if let Err(e) = mgr.restart(&tag) {
                        warn!(conn_key, %tag, "SessionControl restart error: {e}");
                    }
                }
                SessionAction::NewSession => mgr.new_session(&tag),
            }
        }

        ClientMsg::SessionAnswerPermission { tag, .. } => {
            // No stdout-answerable permission path surfaced in the spiked
            // binary; the default posture is bypass and any prompt is answered
            // natively on the phone via remote control. Accepted as a no-op so
            // future binaries / the Swift client can wire it without a protocol
            // change.
            debug!(conn_key, %tag, "SessionAnswerPermission received (no-op in v1)");
        }

        ClientMsg::SessionList => {
            let mgr = session_mgr.lock().unwrap();
            let sessions = mgr.list();
            let _ = targeted_tx.send(ServerMsg::SessionListResp { sessions });
        }

        ClientMsg::FocusRegistryPush { focuses } => {
            let updated = {
                let mut mgr = session_mgr.lock().unwrap();
                mgr.set_focus_registry(focuses)
            };
            // Fan out to every connected, Focuses-subscribed client (incl. this one).
            let _ = broadcast_tx.send(ServerMsg::FocusRegistryUpdated { focuses: updated });
        }

        ClientMsg::FocusList => {
            let focuses = {
                let mgr = session_mgr.lock().unwrap();
                mgr.focus_registry()
            };
            let _ = targeted_tx.send(ServerMsg::FocusListResp { focuses });
        }

        ClientMsg::MotherAction { job_id, action } => {
            let btx = broadcast_tx.clone();
            let conn = conn_key.to_string();
            tokio::spawn(async move {
                let res = match action {
                    MotherActionKind::Cancel     => crate::mother::cancel(&job_id).await,
                    MotherActionKind::Retry      => crate::mother::retry(&job_id).await,
                    MotherActionKind::ForceStart => crate::mother::force_start(&job_id).await,
                    MotherActionKind::Archive    => crate::mother::archive(&job_id).await,
                };
                if let Err(e) = res {
                    tracing::warn!(conn, %job_id, ?action, "MotherAction failed: {e:#}");
                }
                match crate::mother::list_jobs().await {
                    Ok(jobs) => {
                        let _ = btx.send(ServerMsg::MotherJobs { jobs });
                    }
                    Err(e) => tracing::warn!("MotherAction re-poll failed: {e:#}"),
                }
            });
        }

        ClientMsg::MotherResume { job_id, answer } => {
            let btx = broadcast_tx.clone();
            let conn = conn_key.to_string();
            tokio::spawn(async move {
                if let Err(e) = crate::mother::resume(&job_id, &answer).await {
                    tracing::warn!(conn, %job_id, "MotherResume failed: {e:#}");
                }
                match crate::mother::list_jobs().await {
                    Ok(jobs) => {
                        let _ = btx.send(ServerMsg::MotherJobs { jobs });
                    }
                    Err(e) => tracing::warn!("MotherResume re-poll failed: {e:#}"),
                }
            });
        }

        ClientMsg::PerriAction { action, pr_number, repo } => {
            let conn = conn_key.to_string();
            let psd = perri_state_dir.to_path_buf();
            tokio::spawn(async move {
                if let Err(e) = crate::perri_cli::run_perri_action(&action, pr_number, repo.as_deref(), &psd).await {
                    tracing::warn!(conn, %action, "PerriAction failed: {e:#}");
                }
                // The native Perri sources watch dirty-file sentinels; for
                // "load_pr"/"clear" the `perri` CLI writes those sentinels.
                // For "approve" the handler writes approvals.jsonl + queue.dirty
                // directly so the broadcaster fires without a separate re-poll.
            });
        }

        ClientMsg::DecisionAnswer { request_id, choice_id } => {
            let outcome = decisions.lock().unwrap().answer(&request_id, choice_id);
            match outcome {
                AnswerOutcome::Answered { promoted } => {
                    if let Some(msg) = promoted {
                        let _ = broadcast_tx.send(msg);
                    }
                }
                AnswerOutcome::AlreadyAnswered => {
                    warn!(conn_key, %request_id, "DecisionAnswer for an already-answered request");
                }
                AnswerOutcome::UnknownRequest => {
                    warn!(conn_key, %request_id, "DecisionAnswer for an unknown request_id");
                }
            }
        }

        // These are already handled during handshake; ignore duplicates.
        ClientMsg::Hello { .. } | ClientMsg::Subscribe { .. } => {}
    }
}

// ── topic filter ──────────────────────────────────────────────────────────────

fn message_matches_topics(msg: &ServerMsg, topics: &[Topic]) -> bool {
    if topics.is_empty() {
        return true;
    }
    match msg {
        ServerMsg::Activity(_) => topics.contains(&Topic::Activity),
        ServerMsg::MotherJobs { .. } => topics.contains(&Topic::MotherJobs),
        ServerMsg::MotherStatusline(_) => topics.contains(&Topic::MotherStatusline),
        ServerMsg::MotherAwaitDetected(_) => topics.contains(&Topic::MotherJobs),
        ServerMsg::MotherPeek { .. } => topics.contains(&Topic::MotherPeek),
        ServerMsg::TeriState { .. } => topics.contains(&Topic::Teri),
        ServerMsg::FocusRegistryUpdated { .. } => topics.contains(&Topic::Focuses),
        ServerMsg::PerriState { .. } => topics.contains(&Topic::Perri),
        ServerMsg::FredState { .. } => topics.contains(&Topic::Fred),
        // Agent-authored pane layout broadcasts (Phase 1).
        ServerMsg::FocusLayout { .. }
        | ServerMsg::PaneContent { .. }
        | ServerMsg::FocusCreated { .. } => topics.contains(&Topic::Layout),
        ServerMsg::DecisionRequest { .. } => topics.contains(&Topic::Decision),
        // This variant is TUI-internal; the daemon never produces it and should
        // never forward it even if it somehow appears.
        ServerMsg::DaemonReconnected => false,
        // PTY + control messages are always forwarded (handled via targeted channel).
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::message_matches_topics;
    use crate::ipc::protocol::{DecisionChoice, ServerMsg, Topic};

    fn sample_decision_request() -> ServerMsg {
        ServerMsg::DecisionRequest {
            tag: "mother".into(),
            request_id: "req-1".into(),
            prompt: "Ship it?".into(),
            detail: None,
            choices: vec![
                DecisionChoice {
                    id: "approve".into(),
                    label: "Approve".into(),
                    detail: None,
                },
                DecisionChoice {
                    id: "reject".into(),
                    label: "Reject".into(),
                    detail: None,
                },
            ],
            context_pane_id: None,
        }
    }

    #[test]
    fn decision_request_matches_when_subscribed_to_the_decision_topic() {
        assert!(message_matches_topics(
            &sample_decision_request(),
            &[Topic::Decision]
        ));
    }

    #[test]
    fn decision_request_does_not_match_a_subscription_to_some_other_topic() {
        assert!(!message_matches_topics(
            &sample_decision_request(),
            &[Topic::Activity]
        ));
    }

    #[test]
    fn decision_request_matches_an_empty_topic_list_meaning_everything() {
        assert!(message_matches_topics(&sample_decision_request(), &[]));
    }
}
