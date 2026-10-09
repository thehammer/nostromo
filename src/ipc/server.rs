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

use std::collections::BTreeMap;
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
    peer::{
        outbound, refuse_for_network, withheld_msg, PeerTrust, SensitiveTags,
        Transport,
    },
    protocol::{
        ActivityStreamWire, ClientMsg, MotherActionKind, ServerMsg, SessionAction, Topic,
        MIN_CLIENT_VERSION, PROTOCOL_VERSION,
    },
    pty_manager::PtyManager,
    session_manager::SessionManager,
};
use crate::data::work::{
    fred_detail_service, work_service, SendOutcome, SendRequest, SourceState, WorkError, WorkResult,
};

/// The optional capability advertised in `Welcome.features`: this daemon serves
/// the `work` topic and its frames.
const FEATURE_WORK: &str = "work";

/// Latest broadcast frame per retain key (see [`retain_key`]), replayed to a
/// local client that subscribes after the frame was sent.
type RetainedCache = Arc<Mutex<BTreeMap<String, ServerMsg>>>;

/// Handle to the running IPC server.  Drop to shut down.
pub struct Server {
    socket_path: PathBuf,
    pub tx: broadcast::Sender<ServerMsg>,
    retained: RetainedCache,
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

        // Subscribe before returning so no broadcast sent after `bind` can be missed.
        let retained: RetainedCache = Arc::new(Mutex::new(BTreeMap::new()));
        tokio::spawn(retain_broadcasts(tx.subscribe(), Arc::clone(&retained)));

        let retained_for_loop = Arc::clone(&retained);
        tokio::spawn(async move {
            if let Err(e) = accept_loop(listener, tx_clone, pty_mgr, session_mgr, perri_state_dir, decisions, retained_for_loop).await {
                warn!("IPC accept loop exited: {e:#}");
            }
        });

        info!(socket = %socket_path.display(), "IPC server listening");

        Ok(Self {
            socket_path: path,
            tx,
            retained,
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
        let retained = Arc::clone(&self.retained);
        tokio::spawn(async move {
            if let Err(e) = accept_loop_tcp(listener, tx, pty_mgr, session_mgr, perri_state_dir, decisions, retained).await {
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
    retained: RetainedCache,
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
                let retained = Arc::clone(&retained);
                let trust = PeerTrust::from_transport(Transport::Unix);
                tokio::spawn(async move {
                    if let Err(e) = handle_client(stream, trust, rx, broadcast_tx, pty_mgr, session_mgr, psd, decisions, retained).await {
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
    retained: RetainedCache,
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
                let retained = Arc::clone(&retained);
                let trust = PeerTrust::from_transport(Transport::Tcp);
                tokio::spawn(async move {
                    if let Err(e) = handle_client(stream, trust, rx, broadcast_tx, pty_mgr, session_mgr, psd, decisions, retained).await {
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
///
/// `trust` says how far this peer is trusted (derived from its transport by the
/// accept loop). A network peer is never sent Teri/Fred data and its requests
/// for it are refused; see [`super::peer`].
#[allow(clippy::too_many_arguments)]
async fn handle_client<S>(
    stream: S,
    trust: PeerTrust,
    mut broadcast_rx: broadcast::Receiver<ServerMsg>,
    broadcast_tx: broadcast::Sender<ServerMsg>,
    pty_mgr: Arc<Mutex<PtyManager>>,
    session_mgr: Arc<Mutex<SessionManager>>,
    perri_state_dir: PathBuf,
    decisions: Arc<Mutex<DecisionRegistry>>,
    retained: RetainedCache,
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
        features: vec![FEATURE_WORK.to_string()],
    };
    write_frame(&mut writer, &serde_json::to_vec(&welcome)?).await?;
    debug!(claimed_id, conn_key, "client welcomed");

    // ── Subscribe ─────────────────────────────────────────────────────────────

    let sub_bytes = read_frame(&mut reader).await?;
    let sub: ClientMsg = serde_json::from_slice(&sub_bytes)?;

    let (mut topics, renders_decisions): (Vec<Topic>, bool) = match sub {
        ClientMsg::Subscribe { topics, renders_decisions } => (topics, renders_decisions),
        ClientMsg::Ping => {
            write_frame(&mut writer, &serde_json::to_vec(&ServerMsg::Pong)?).await?;
            (vec![], false)
        }
        other => {
            anyhow::bail!("expected Subscribe, got {other:?}");
        }
    };

    info!(claimed_id, conn_key, ?topics, renders_decisions, "client subscribed");

    // ── Decision-modal operator accounting (W6) ───────────────────────────────
    // An empty `topics` list still means "deliver everything" for routing (see
    // `message_matches_topics`) — that is unchanged. But it no longer ALSO
    // means "I am an operator": a client that can't render a decision (e.g.
    // iOS, which subscribes with `topics: []` to get every broadcast) must not
    // be counted, or `nostromo.ask_decision`'s `no_operator` fail-fast gate is
    // defeated by a client that can never answer. A connection counts as an
    // operator iff it named `Topic::Decision` explicitly, or set
    // `renders_decisions: true` — the only way to make that claim without a
    // full topic enumeration when subscribing to everything.
    let mut is_operator = topics.contains(&Topic::Decision) || renders_decisions;
    if is_operator {
        decisions.lock().unwrap().add_operator(&conn_key);
    }

    // ── Register per-client targeted channel ──────────────────────────────────
    // Use `conn_key` (server-minted UUID) as the registry key — not the
    // client-supplied `claimed_id` — so no remote peer can impersonate an
    // existing connection by guessing or replaying another client's id.

    // Which tags/jobs carry Teri/Fred-derived content. Held as a handle so the
    // write path never takes the session manager's lock.
    let sensitive = session_mgr.lock().unwrap().sensitive_tags();

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
    if subscribed(&topics, Topic::Layout) {
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
            // Clone the provider handle and drop the lock before calling into
            // it — `bound_pane_contents()` can reach a `get_file`-bound pane's
            // `file_root()`, which locks this exact `Arc<Mutex<SessionManager>>`
            // again to resolve the focus's cwd. `std::sync::Mutex` is not
            // reentrant, so holding the guard across that call self-deadlocks
            // the connection handler the moment any pane is bound to
            // `nostromo.get_file` — on every reconnect and every daemon-restart
            // replay, not as a rare corner case.
            let provider = session_mgr.lock().unwrap().pane_content_provider();
            if let Some(provider) = provider {
                snapshots.extend(provider.bound_pane_contents());
            }
        }
        // A network peer is replayed only what it could also be sent live: the
        // layout and pane content of a sensitive focus never leave this box.
        // (Pane content of an ordinary dynamic focus is still replayed — the
        // exposure of the rest of the daemon is tracked separately, see
        // `peer.rs`.)
        replay_messages(
            &mut writer,
            snapshots.into_iter().filter_map(|m| outbound(trust, m, &sensitive)),
        )
        .await;
    }

    // ── Activity replay — snapshot + health on (re)connect ────────────────────
    // A reconnecting client must never be left presenting a stale last-known
    // event as if it were current, and it must be able to tell a genuinely
    // quiet focus apart from a broken ingestion path — so both a snapshot per
    // known focus and one health verdict are pushed immediately on attach,
    // mirroring the Layout replay above (D4).
    if topics.contains(&Topic::Activity) {
        let (snapshots, health_msg): (Vec<ServerMsg>, ServerMsg) = {
            let mgr = session_mgr.lock().unwrap();
            let snapshots = mgr
                .known_focus_tags()
                .into_iter()
                .map(|tag| {
                    let streams = activity_streams_wire(&mgr, &tag);
                    ServerMsg::ActivitySnapshot { tag, streams }
                })
                .collect();

            let hook_installed = crate::activity::hook_status::hook_installed(
                &crate::activity::hook_status::default_settings_path(),
            );
            let health_msg = activity_health_msg(&mgr, hook_installed);
            (snapshots, health_msg)
        };
        replay_messages(
            &mut writer,
            snapshots
                .into_iter()
                .chain(std::iter::once(health_msg))
                .filter_map(|m| outbound(trust, m, &sensitive)),
        )
        .await;
    }

    // ── Perri replay — push the current queue/current-PR to a new client ──
    // `PerriState` is only broadcast on watch change, and the daemon's one
    // initial broadcast happens at daemon start, not per attach. Without this
    // a client attaching to a running daemon shows an empty PR list for up to
    // `pr_queue_poll_secs` (60s) — visible on iOS, whose Perri tab and tab
    // badge read `DaemonStore.perriQueue`.
    //
    // Per focus (W7 — D7), exactly like the broadcaster: one frame for each
    // focus the daemon would address, each carrying only that focus's PR.
    // The provider lives inside `SessionManager`, so take what it needs under
    // the lock and call it after the lock is released.
    if subscribed(&topics, Topic::Perri) {
        let (provider, focus_tags) = {
            let mgr = session_mgr.lock().unwrap();
            let tags: Vec<String> = mgr.focus_registry().into_iter().map(|f| f.tag).collect();
            (mgr.perri_state_provider(), tags)
        };
        let frames = provider.map(|p| p.perri_states(&focus_tags)).unwrap_or_default();
        replay_messages(&mut writer, frames.into_iter().filter_map(|m| outbound(trust, m, &sensitive)))
            .await;
    }

    // ── Retained replay — latest Teri/Fred/work frames, local clients only ────
    // A network peer is never replayed anything retained (all of it is
    // sensitive); it gets one `Withheld` notice instead.
    if trust.is_network() {
        replay_messages(&mut writer, [withheld_msg()]).await;
    } else {
        replay_messages(&mut writer, retained_matching(&retained, &topics, None)).await;
    }

    // ── Main loop (broadcast + targeted + client reads) ───────────────────────

    let result: Result<()> = loop {
        tokio::select! {
            // Broadcast events (activity, Mother, etc.)
            bcast = broadcast_rx.recv() => {
                match bcast {
                    Ok(msg) => {
                        // Trust gate first: a network peer never gets a
                        // sensitive frame, whatever its topic list says.
                        if !message_matches_topics(&msg, &topics) {
                            continue;
                        }
                        let Some(msg) = outbound(trust, msg, &sensitive) else {
                            continue;
                        };
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
                // Targeted frames (session transcripts, replies, summaries)
                // go through the same gate as broadcasts; the only
                // sensitive frames a network peer gets are refusals.
                let Some(msg) = outbound(trust, msg, &sensitive) else {
                    continue;
                };
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
                        // A later `Subscribe` replaces the topic list: a client
                        // that learned from `Welcome.features` that the daemon
                        // serves `work` adds it this way.
                        if let ClientMsg::Subscribe { topics: new_topics, renders_decisions } = msg {
                            if !is_operator && (new_topics.contains(&Topic::Decision) || renders_decisions) {
                                decisions.lock().unwrap().add_operator(&conn_key);
                                is_operator = true;
                            }
                            // Replay retained frames only for the topics this
                            // subscribe adds; a network peer gets none.
                            let frames = if trust.is_network() {
                                vec![]
                            } else {
                                retained_matching(&retained, &new_topics, Some(&topics))
                            };
                            topics = new_topics;
                            replay_messages(&mut writer, frames).await;
                            continue;
                        }
                        handle_client_msg(msg, trust, &sensitive, &conn_key, &pty_mgr, &session_mgr, &targeted_tx, &broadcast_tx, &perri_state_dir, &decisions);
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
    if is_operator {
        decisions.lock().unwrap().remove_operator(&conn_key);
    }

    result
}

/// Serialize and write each message in order, best-effort: a message that
/// fails to serialize (or serializes to nothing) is skipped rather than
/// aborting the rest of the replay, and a write failure is swallowed — the
/// client will find out on its next read once the socket is actually down.
/// Shared by the Layout and Activity replay blocks in `handle_client`, which
/// both push an ordered batch of `ServerMsg`s to a freshly (re)connected
/// client before entering the main loop.
async fn replay_messages<W>(writer: &mut W, messages: impl IntoIterator<Item = ServerMsg>)
where
    W: AsyncWrite + Unpin,
{
    for msg in messages {
        let bytes = serde_json::to_vec(&msg).unwrap_or_default();
        if !bytes.is_empty() {
            let _ = write_frame(writer, &bytes).await;
        }
    }
}

// ── PTY command dispatch ──────────────────────────────────────────────────────

/// `conn_key` is the server-minted UUID for this connection (not the
/// client-supplied `client_id` from the Hello frame).
///
/// Eight shared-state handles, one per subsystem this dispatch touches —
/// matches the existing precedent on `McpSharedState::new` (ten arguments,
/// same allowance) rather than introducing a bundling struct for a single
/// internal dispatch function.
#[allow(clippy::too_many_arguments)]
fn handle_client_msg(
    msg: ClientMsg,
    trust: PeerTrust,
    sensitive: &SensitiveTags,
    conn_key: &str,
    pty_mgr: &Arc<Mutex<PtyManager>>,
    session_mgr: &Arc<Mutex<SessionManager>>,
    targeted_tx: &mpsc::UnboundedSender<ServerMsg>,
    broadcast_tx: &broadcast::Sender<ServerMsg>,
    perri_state_dir: &Path,
    decisions: &Arc<Mutex<DecisionRegistry>>,
) {
    // Deny-by-default for network peers: a sensitive request, or any request
    // that reads or drives a Teri/Fred-derived session, changes nothing.
    if trust.is_network()
        && (refuse_for_network(&msg, sensitive) || answers_sensitive_decision(&msg, sensitive, decisions))
    {
        refuse_over_network(&msg, targeted_tx);
        return;
    }

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

        ClientMsg::ClosePane { tag, pane_id } => {
            let mgr = session_mgr.lock().unwrap();
            let Some(reg) = mgr.pane_registry() else {
                let _ = targeted_tx.send(ServerMsg::Error {
                    message: "ClosePane failed: no pane registry".into(),
                });
                return;
            };
            let result = reg.lock().unwrap().close_tab(&tag, &pane_id);
            match result {
                Ok(tree) => {
                    // Same broadcast every layout mutation uses, so every client
                    // (each window, iOS) re-renders from the daemon's tree.
                    let _ = broadcast_tx.send(ServerMsg::FocusLayout {
                        tag,
                        tree,
                        focused_pane: None,
                    });
                }
                Err(e) => {
                    warn!(conn_key, %tag, %pane_id, "ClosePane refused: {}", e.code());
                    let _ = targeted_tx.send(ServerMsg::Error {
                        message: format!("ClosePane failed: {}", e.code()),
                    });
                }
            }
        }

        ClientMsg::SessionInterrupt { tag } => {
            let mut mgr = session_mgr.lock().unwrap();
            if let Err(e) = mgr.interrupt(&tag) {
                warn!(conn_key, %tag, "SessionInterrupt error: {e}");
                let _ = targeted_tx.send(ServerMsg::Error {
                    message: format!("SessionInterrupt failed: {e}"),
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
            let (updated, departed, reconcilable, pane_registry) = {
                let mut mgr = session_mgr.lock().unwrap();
                if !trust.is_network() {
                    mgr.mark_teri_fred_focuses(&focuses);
                }
                let (updated, departed) = mgr.set_focus_registry(focuses);
                (
                    updated,
                    departed,
                    mgr.reconcilable_focus_tags(),
                    mgr.pane_registry(),
                )
            };

            // W7 — D8: a focus that is gone takes its per-focus state with it.
            // This is the daemon's only signal that a focus was removed — the
            // Mac detaches rather than stopping the session, so nothing else
            // ever says so. `set_focus_registry` has already applied the
            // reconnect and daemon-created guards, so anything here is a
            // genuine departure.
            //
            // The pin is deleted outright rather than tombstoned, because
            // `nostromo.create_focus` derives its tag deterministically from
            // `(agent, title)` — close and recreate the same focus and the tag
            // comes back. Anything less than deletion would hand the new focus
            // the dead one's PR, which is the PRD's "a removed focus's pin
            // never resurfaces" criterion failing.
            for tag in &departed {
                match crate::data::perri_current_pr::remove_pin(perri_state_dir, tag) {
                    Ok(true) => {
                        tracing::info!(tag = %tag, "focus removed — discarded its PR pin")
                    }
                    Ok(false) => {}
                    Err(e) => {
                        tracing::warn!(tag = %tag, "focus removed but its PR pin could not be discarded: {e}")
                    }
                }
                if let Some(reg) = &pane_registry {
                    if reg.lock().unwrap().remove_focus(tag) {
                        tracing::info!(tag = %tag, "focus removed — discarded its pane tree and bindings");
                    }
                }
            }

            // W7 — D8 backstop. The loop above is the primary mechanism, and it
            // only ever sees removals this daemon was running to witness. A
            // focus removed while the daemon was down, or whose push was never
            // delivered, leaves a pin on disk that no departure will ever name
            // — and `nostromo.create_focus`'s deterministic tag means the next
            // focus of the same name would be handed it.
            //
            // `reconcilable_focus_tags` is `None` until this daemon can vouch
            // for a complete picture (see its doc comment), which is what keeps
            // this from weakening D8a: it can never collect a pin the loop
            // above would have spared.
            if let Some(live) = reconcilable {
                let sweep = crate::data::perri_current_pr::retain_pins(perri_state_dir, &live);
                if !sweep.dropped.is_empty() {
                    tracing::info!(
                        tags = ?sweep.dropped,
                        "discarded PR pins for focuses that no longer exist"
                    );
                }
                // A backstop that tried and failed must not look like one that
                // had nothing to do: the pins it could not remove are exactly
                // the zombies it exists to stop, still on disk and still
                // waiting for `create_focus` to hand them to a reused tag.
                if !sweep.errors.is_empty() {
                    tracing::warn!(
                        errors = ?sweep.errors,
                        "PR pins for departed focuses could not be discarded"
                    );
                }
            }

            // A review focus (Perri) opens with the review queue as its first
            // tab; an old queue-beside-detail layout is migrated to match. This
            // is the moment the Mac app has just told us which focuses exist, so
            // it covers launch. Clients are told the new tree like any layout
            // change.
            if let Some(reg) = &pane_registry {
                let mut reg = reg.lock().unwrap();
                for focus in &updated {
                    let seeded = reg
                        .ensure_review_layout(&focus.tag)
                        .or_else(|| reg.ensure_mother_layout(&focus.tag));
                    if let Some(tree) = seeded {
                        let _ = broadcast_tx.send(ServerMsg::FocusLayout {
                            tag: focus.tag.clone(),
                            tree,
                            focused_pane: None,
                        });
                    }
                }
            }

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

        ClientMsg::PerriAction {
            action,
            pr_number,
            repo,
            tag,
        } => {
            let conn = conn_key.to_string();
            let psd = perri_state_dir.to_path_buf();
            // W7: the PR under review belongs to a focus. A client that names
            // one drives that focus; one that doesn't (a pre-W7 build) drives
            // the built-in `perri` focus, which is where its single PR surface
            // was.
            let tag =
                tag.unwrap_or_else(|| crate::data::perri_current_pr::BUILTIN_PERRI_TAG.to_owned());
            tokio::spawn(async move {
                if let Err(e) = crate::perri_cli::run_perri_action(
                    &action,
                    pr_number,
                    repo.as_deref(),
                    &tag,
                    &psd,
                )
                .await
                {
                    tracing::warn!(conn, %action, "PerriAction failed: {e:#}");
                }
                // The native Perri sources watch dirty-file sentinels; all
                // three actions write their own sentinels in-process now.
                // "load_pr"/"clear" write through `perri_current_pr`
                // (current-pr.dirty, and "clear" also touches queue.dirty).
                // "approve" writes approvals.jsonl + queue.dirty directly.
                // Either way the broadcaster fires without a separate re-poll.
            });
        }

        ClientMsg::DecisionAnswer { request_id, choice_id } => {
            let outcome = decisions.lock().unwrap().answer(&request_id, choice_id);
            match outcome {
                AnswerOutcome::Answered { promoted } => {
                    if let Some(msg) = promoted {
                        let _ = broadcast_tx.send(*msg);
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

        ClientMsg::ActivitySnapshotRequest { tag } => {
            let streams = {
                let mgr = session_mgr.lock().unwrap();
                activity_streams_wire(&mgr, &tag)
            };
            let _ = targeted_tx.send(ServerMsg::ActivitySnapshot { tag, streams });
        }

        ClientMsg::RenderedShape {
            tag,
            window_id,
            pane_ids,
            rendered_at,
        } => {
            let mgr = session_mgr.lock().unwrap();
            if let Some(reg) = mgr.pane_registry() {
                reg.lock().unwrap()
                    .record_rendered_shape(conn_key, &window_id, &tag, pane_ids, rendered_at);
            }
        }

        // ── Teri/Fred work views (local peers only; network refused above) ───
        ClientMsg::WorkDetailRequest { request_id, item_id } => {
            let tx = targeted_tx.clone();
            tokio::spawn(async move {
                let result = if item_id.starts_with("mail:") || item_id.starts_with("event:") {
                    fred_detail_service().detail(&item_id).await
                } else {
                    work_service().detail(&item_id).await
                };
                let _ = tx.send(ServerMsg::WorkDetail { request_id, result: result.into() });
            });
        }

        ClientMsg::WorkRefresh { source, fred } => {
            tokio::spawn(async move {
                if let Err(e) = work_service().refresh(source, fred).await {
                    debug!(code = %e.code, "WorkRefresh not performed");
                }
            });
        }

        ClientMsg::PicksRefresh { reason } => {
            tokio::spawn(async move {
                if let Err(e) = work_service().refresh_picks(&reason).await {
                    debug!(code = %e.code, "PicksRefresh not performed");
                }
            });
        }

        ClientMsg::WorkSendPreviewRequest { request_id, item_id } => {
            let tx = targeted_tx.clone();
            tokio::spawn(async move {
                let result = work_service().send_preview(&item_id).await;
                let _ = tx.send(ServerMsg::WorkSendPreview { request_id, result: result.into() });
            });
        }

        ClientMsg::WorkSend {
            request_id,
            item_id,
            destination,
            agent,
            working_directory,
            label,
            context,
            allow_duplicate,
        } => {
            let tx = targeted_tx.clone();
            let request = SendRequest {
                item_id,
                destination,
                agent,
                working_directory,
                label,
                context,
                allow_duplicate,
            };
            let sensitive = sensitive.clone();
            tokio::spawn(async move {
                let result = work_service().send(request).await;
                // Whatever the send created now holds work-item content: its
                // focus transcript, panes and metadata, or its Mother job, are
                // withheld from network peers from here on. (A service that
                // broadcasts the new focus before returning should register it
                // itself first; see `WorkService::send`.)
                if let Ok(outcome) = &result {
                    if let Some(tag) = &outcome.focus_tag {
                        sensitive.mark_tag(tag);
                    }
                    if let Some(job_id) = &outcome.job_id {
                        sensitive.mark_job(job_id);
                    }
                }
                let _ = tx.send(ServerMsg::WorkSendResult { request_id, result: result.into() });
            });
        }

        ClientMsg::FredSeed { request_id, text } => {
            let result = seed_fred(session_mgr, &text);
            let _ = targeted_tx.send(ServerMsg::WorkSendResult { request_id, result });
        }

        // These are already handled during handshake; ignore duplicates.
        ClientMsg::Hello { .. } | ClientMsg::Subscribe { .. } => {}
    }
}

/// Session tag of Fred's own session.
const FRED_TAG: &str = "fred";

/// Send `text` into Fred's session as a user message.
fn seed_fred(
    session_mgr: &Arc<Mutex<SessionManager>>,
    text: &str,
) -> WorkResult<SendOutcome> {
    let mut mgr = session_mgr.lock().unwrap();
    if !mgr.has_live_session(FRED_TAG) {
        return WorkResult::err("fred_not_running", "Fred's session is not running");
    }
    match mgr.send_user_message(FRED_TAG, text, &[]) {
        Ok(()) => WorkResult::Ok(SendOutcome {
            kind: "seeded".into(),
            focus_tag: Some(FRED_TAG.into()),
            job_id: None,
        }),
        Err(e) => {
            warn!("FredSeed failed: {e:#}");
            WorkResult::err("fred_seed_failed", format!("could not send to Fred: {e}"))
        }
    }
}

/// Is `msg` an answer to a decision request of a sensitive focus? The request
/// id is unguessable and its request is never sent to a network peer, so this
/// is defence in depth for a leaked id.
fn answers_sensitive_decision(
    msg: &ClientMsg,
    sensitive: &SensitiveTags,
    decisions: &Arc<Mutex<DecisionRegistry>>,
) -> bool {
    let ClientMsg::DecisionAnswer { request_id, .. } = msg else {
        return false;
    };
    decisions
        .lock()
        .unwrap()
        .tag_of_active(request_id)
        .is_some_and(|tag| sensitive.tag_is_sensitive(&tag))
}

/// Answer a sensitive request from a network peer with
/// `requires_secure_connection`, in the targeted frame that matches the
/// request (or a plain `Error` for requests that have no result frame).
fn refuse_over_network(msg: &ClientMsg, targeted_tx: &mpsc::UnboundedSender<ServerMsg>) {
    let refusal = WorkError::requires_secure_connection();
    let reply = match msg {
        ClientMsg::WorkDetailRequest { request_id, .. } => ServerMsg::WorkDetail {
            request_id: request_id.clone(),
            result: WorkResult::Err(refusal),
        },
        ClientMsg::WorkSendPreviewRequest { request_id, .. } => ServerMsg::WorkSendPreview {
            request_id: request_id.clone(),
            result: WorkResult::Err(refusal),
        },
        ClientMsg::WorkSend { request_id, .. } | ClientMsg::FredSeed { request_id, .. } => {
            ServerMsg::WorkSendResult {
                request_id: request_id.clone(),
                result: WorkResult::Err(refusal),
            }
        }
        _ => ServerMsg::Error {
            message: format!("{}: {}", refusal.code, refusal.message),
        },
    };
    let _ = targeted_tx.send(reply);
}

// ── retained-message cache ────────────────────────────────────────────────────

/// Key under which a broadcast frame is remembered, or `None` if it is not
/// retained. Only the latest frame per key is kept.
fn retain_key(msg: &ServerMsg) -> Option<String> {
    match msg {
        ServerMsg::FredState { .. } => Some("fred".to_string()),
        ServerMsg::TeriState { .. } => Some("teri".to_string()),
        ServerMsg::WorkSourceStatus { status } => Some(format!("status:{}", status.source.as_str())),
        ServerMsg::WorkSnapshot { source, group, .. } => Some(format!(
            "work:{}:{}",
            source.as_str(),
            group.as_deref().unwrap_or("")
        )),
        ServerMsg::TeriPicks { .. } => Some("picks".to_string()),
        _ => None,
    }
}

/// Retained frames a client subscribed to `topics` should be replayed, minus
/// those it was already subscribed to under `already` (`None` = a first
/// subscribe, nothing was delivered yet).
fn retained_matching(
    retained: &RetainedCache,
    topics: &[Topic],
    already: Option<&[Topic]>,
) -> Vec<ServerMsg> {
    retained
        .lock()
        .unwrap()
        .values()
        .filter(|m| {
            message_matches_topics(m, topics)
                && already.is_none_or(|old| !message_matches_topics(m, old))
        })
        .cloned()
        .collect()
}

/// Update the retained cache for one broadcast frame: remember the latest
/// frame per key, and forget what the source says is gone — a group that
/// reports no items, and every group of a source that is no longer configured.
fn apply_retention(cache: &mut BTreeMap<String, ServerMsg>, msg: ServerMsg) {
    match &msg {
        ServerMsg::WorkSnapshot { items, .. } if items.is_empty() => {
            if let Some(key) = retain_key(&msg) {
                cache.remove(&key);
            }
            return;
        }
        ServerMsg::WorkSourceStatus { status } if status.state == SourceState::NotConfigured => {
            let prefix = format!("work:{}:", status.source.as_str());
            cache.retain(|key, _| !key.starts_with(&prefix));
        }
        _ => {}
    }
    if let Some(key) = retain_key(&msg) {
        cache.insert(key, msg);
    }
}

/// Remember the latest retained frame per key until the broadcast channel closes.
///
/// If this task falls behind the channel it cannot know which retained frames
/// it missed (including a removal), so it clears the cache rather than serve
/// state it can no longer vouch for; the sources re-broadcast on their next
/// change or refresh.
async fn retain_broadcasts(mut rx: broadcast::Receiver<ServerMsg>, cache: RetainedCache) {
    loop {
        match rx.recv().await {
            Ok(msg) => apply_retention(&mut cache.lock().unwrap(), msg),
            Err(broadcast::error::RecvError::Lagged(n)) => {
                warn!("retained-message cache lagged {n} broadcast messages; clearing it");
                cache.lock().unwrap().clear();
            }
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}

/// Snapshot one focus's activity streams into their wire form.
fn activity_streams_wire(mgr: &SessionManager, tag: &str) -> Vec<ActivityStreamWire> {
    mgr.activity_streams_for_focus(tag)
        .into_iter()
        .map(|s| ActivityStreamWire {
            agent_id: s.agent_id,
            agent_type: s.agent_type,
            parent_agent_id: s.parent_agent_id,
            events: s.events,
            finished: s.finished,
        })
        .collect()
}

// ── topic filter ──────────────────────────────────────────────────────────────

/// A client that subscribed with an empty topic list gets everything — the
/// rule `message_matches_topics` applies to broadcasts. Attach-replay gates
/// must use this too, or a client (iOS sends `topics: []`) silently receives
/// live broadcasts for a topic it was never replayed.
fn subscribed(topics: &[Topic], topic: Topic) -> bool {
    topics.is_empty() || topics.contains(&topic)
}

fn message_matches_topics(msg: &ServerMsg, topics: &[Topic]) -> bool {
    match msg {
        ServerMsg::Activity(_)
        | ServerMsg::ActivitySnapshot { .. }
        | ServerMsg::ActivityHealth { .. } => subscribed(topics, Topic::Activity),
        ServerMsg::MotherJobs { .. } => subscribed(topics, Topic::MotherJobs),
        ServerMsg::MotherStatusline(_) => subscribed(topics, Topic::MotherStatusline),
        ServerMsg::MotherAwaitDetected(_) => subscribed(topics, Topic::MotherJobs),
        ServerMsg::MotherPeek { .. } => subscribed(topics, Topic::MotherPeek),
        ServerMsg::TeriState { .. } => subscribed(topics, Topic::Teri),
        ServerMsg::WorkSourceStatus { .. }
        | ServerMsg::WorkSnapshot { .. }
        | ServerMsg::TeriPicks { .. } => subscribed(topics, Topic::Work),
        ServerMsg::FocusRegistryUpdated { .. } => subscribed(topics, Topic::Focuses),
        ServerMsg::PerriState { .. } => subscribed(topics, Topic::Perri),
        ServerMsg::FredState { .. } => subscribed(topics, Topic::Fred),
        // Agent-authored pane layout broadcasts (Phase 1). `Notification`
        // (W5 — current-pr-collision) reuses this topic rather than adding
        // a new one, deliberately: every client that already renders
        // FocusLayout/PaneContent has already subscribed to it, so an older
        // client can't silently miss a Notification just because it never
        // learned about a topic that postdates it.
        ServerMsg::FocusLayout { .. }
        | ServerMsg::PaneContent { .. }
        | ServerMsg::FocusCreated { .. }
        | ServerMsg::Notification { .. } => subscribed(topics, Topic::Layout),
        ServerMsg::DecisionRequest { .. } | ServerMsg::DecisionResolved { .. } => {
            subscribed(topics, Topic::Decision)
        }
        // This variant is TUI-internal; the daemon never produces it and should
        // never forward it even if it somehow appears.
        ServerMsg::DaemonReconnected => false,
        // PTY + control messages are always forwarded (handled via targeted channel).
        _ => true,
    }
}

/// The `ActivityHealth` verdict for `mgr`, given whether the ambient-activity
/// hook is installed. Shared by the attach-time replay and by the broadcast
/// the daemon sends when ingestion first begins, so a connected client's
/// footer is corrected without a reconnect (it used to keep saying "install
/// the hook" until the app relaunched).
pub fn activity_health_msg(mgr: &SessionManager, hook_installed: bool) -> ServerMsg {
    let health = mgr.activity_health();
    let reason = if health.ingesting {
        None
    } else if hook_installed {
        Some("activity hook installed but no event has arrived yet".to_string())
    } else {
        Some(
            "activity hook not installed — run `bin/nostromo-doctor --fix` to install it"
                .to_string(),
        )
    };
    ServerMsg::ActivityHealth {
        ingesting: health.ingesting,
        reason,
        last_event_at: health.last_event_at,
        hook_installed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::protocol::DecisionChoice;

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

    // ── DecisionResolved routes under Topic::Decision too (multi-window fix) ──
    //
    // Every window's sheet needs to learn a request resolved, not just the
    // window whose sheet the operator actually used — that propagation rides
    // the same Topic::Decision gate as the original DecisionRequest.

    fn sample_decision_resolved() -> ServerMsg {
        ServerMsg::DecisionResolved {
            tag: "mother".into(),
            request_id: "req-1".into(),
            resolution: crate::ipc::protocol::DecisionResolution::Answered,
            choice_id: Some("approve".into()),
        }
    }

    #[test]
    fn decision_resolved_matches_when_subscribed_to_the_decision_topic() {
        assert!(message_matches_topics(
            &sample_decision_resolved(),
            &[Topic::Decision]
        ));
    }

    #[test]
    fn decision_resolved_does_not_match_a_subscription_to_some_other_topic() {
        assert!(!message_matches_topics(
            &sample_decision_resolved(),
            &[Topic::Activity]
        ));
    }

    #[test]
    fn decision_resolved_matches_an_empty_topic_list_meaning_everything() {
        assert!(message_matches_topics(&sample_decision_resolved(), &[]));
    }

    // ── ServerMsg::Notification routes under Topic::Layout (W5 —
    // current-pr-collision) ───────────────────────────────────────────────────
    //
    // Reuses the existing topic the macOS client already subscribes to for
    // pane-layout traffic — no new `Topic` variant, no client-side
    // subscribe-list change needed. No production caller sends a
    // `Notification` yet (that lands a wedge later), so this is proven
    // directly: the pure predicate, and — because nothing else exercises this
    // path — the real `tokio::sync::broadcast` transport end to end.

    fn sample_notification() -> ServerMsg {
        ServerMsg::Notification {
            tag: "perri".into(),
            level: crate::ipc::protocol::NotificationLevel::Warning,
            message: "test".into(),
        }
    }

    #[test]
    fn notification_matches_when_subscribed_to_the_layout_topic() {
        assert!(message_matches_topics(&sample_notification(), &[Topic::Layout]));
    }

    #[test]
    fn notification_does_not_match_a_subscription_to_some_other_topic() {
        assert!(!message_matches_topics(&sample_notification(), &[Topic::Activity]));
    }

    #[test]
    fn notification_matches_an_empty_topic_list_meaning_everything() {
        assert!(message_matches_topics(&sample_notification(), &[]));
    }

    #[tokio::test]
    async fn a_notification_sent_through_a_real_broadcast_channel_still_carries_its_tag_and_topic_gate(
    ) {
        // Proves the actual `tokio::sync::broadcast` plumbing carries the
        // variant intact end to end — not just the pure predicate above —
        // since no real trigger calls this path for at least one more wedge
        // and it must still be demonstrably wired correctly today.
        let (tx, mut rx) = broadcast::channel::<ServerMsg>(8);
        tx.send(sample_notification()).expect("send into a fresh channel");

        let received = rx.recv().await.expect("receive back out");

        assert!(message_matches_topics(&received, &[Topic::Layout]));
        assert!(!message_matches_topics(&received, &[Topic::Activity]));
        match received {
            ServerMsg::Notification { tag, .. } => assert_eq!(tag, "perri"),
            other => panic!("expected Notification, got {other:?}"),
        }
    }

    // ── ambient activity routes under Topic::Activity ─────────────────────────

    #[test]
    fn activity_snapshot_and_health_route_under_topic_activity() {
        let snapshot = ServerMsg::ActivitySnapshot {
            tag: "cody-1".into(),
            streams: Vec::<ActivityStreamWire>::new(),
        };
        let health = ServerMsg::ActivityHealth {
            ingesting: true,
            reason: None,
            last_event_at: None,
            hook_installed: true,
        };

        assert!(message_matches_topics(&snapshot, &[Topic::Activity]));
        assert!(message_matches_topics(&health, &[Topic::Activity]));

        // A subscription to an unrelated topic must not see either message
        // (empty `topics` is the "no filter" wildcard, so use a concrete,
        // different topic here).
        assert!(!message_matches_topics(&snapshot, &[Topic::Fred]));
        assert!(!message_matches_topics(&health, &[Topic::Fred]));
    }

    #[test]
    fn the_health_message_flips_from_a_reason_to_none_once_an_event_is_ingested() {
        let mut mgr = SessionManager::with_store_path(
            std::env::temp_dir().join(format!("nostromo-health-{}.json", std::process::id())),
        );
        match activity_health_msg(&mgr, false) {
            ServerMsg::ActivityHealth { ingesting, reason, hook_installed, .. } => {
                assert!(!ingesting);
                assert!(!hook_installed);
                assert!(reason.unwrap().contains("bin/nostromo-doctor --fix"));
            }
            other => panic!("expected ActivityHealth, got {other:?}"),
        }

        mgr.ingest_activity_event(crate::agent_bus::ActivityEvent {
            ts: chrono::Utc::now(),
            agent: "Bash".into(),
            kind: "tool_use".into(),
            summary: "ls".into(),
            focus_tag: Some("fred".into()),
            session_id: None,
            agent_type: None,
            tool_name: Some("Bash".into()),
            tool_use_id: None,
            cwd: None,
            agent_id: None,
            parent_agent_id: None,
            seq: None,
        });

        match activity_health_msg(&mgr, true) {
            ServerMsg::ActivityHealth { ingesting, reason, last_event_at, .. } => {
                assert!(ingesting);
                assert!(reason.is_none(), "a healthy ingest must clear the reason that told the operator to install the hook");
                assert!(last_event_at.is_some());
            }
            other => panic!("expected ActivityHealth, got {other:?}"),
        }
    }
}
