//! Daemon-side IPC server.
//!
//! Accepts Unix socket connections, performs the `Hello`/`Welcome` handshake,
//! fans out broadcast `ServerMsg`s to subscribed clients, **and** handles
//! incoming session commands from each client.
//!
//! ## Architecture
//!
//! Each connected client runs in its own `handle_client` task.  The task
//! maintains a three-way `tokio::select!`:
//!
//! 1. **Broadcast** — activity / Mother events → write to socket.
//! 2. **Targeted** — session output / control messages aimed at this client.
//! 3. **Socket reads** — incoming `ClientMsg`.
//!
//! The targeted channel is registered with the session manager's
//! client-sender registry on connect and removed on disconnect.

use std::collections::{BTreeMap, HashSet};
use std::os::fd::{AsFd, OwnedFd};
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
        outbound, refuse_for_network, withheld_msg, within_work_send, PeerTrust,
        SensitiveTags, Transport,
    },
    peer_verify::{classify_peer, claim_diagnostic, still_same_operator, PeerInfo, PeerVerifier, MAC_APP_CLIENT_KIND},
    protocol::{
        ActivityStreamWire, ClaudeLoginActionKind, ClientMsg, MotherActionKind, ServerMsg, SessionAction, Topic,
        FEATURE_LOGIN, MAX_FRAME_LEN, MIN_CLIENT_VERSION, PROTOCOL_VERSION,
    },
    session_manager::{ModelRequestOutcome, ResendTrigger, SessionManager, SwitchRequest},
};
use crate::approvals::broker::ApprovalBroker;
use crate::approvals::wire::{AnswerRefusal, RefusalChannel};
use crate::data::work::{
    fred_detail_service, work_service, SendOutcome, SendRequest, SourceState, WorkError, WorkResult,
};

/// The answer to every retired `ClientMsg::Pty*` verb.
const PTY_HOST_REMOVED: &str = "pty_host_removed: the daemon no longer hosts PTYs (the Rust TUI was removed)";

/// The refusal a `DecisionAnswer` from anyone but the verified Mac app gets.
const NOT_OPERATOR_APP: &str = "not_operator_app: only the verified Nostromo app may answer";

/// The optional capability advertised in `Welcome.features`: this daemon serves
/// the `work` topic and its frames.
const FEATURE_WORK: &str = "work";

/// The optional capability advertised in `Welcome.features`: this daemon serves
/// the `model` topic (model switching frames).
const FEATURE_MODEL: &str = "model";

/// The optional capability advertised in `Welcome.features`: this daemon sends
/// `session_tasks` and `session_task_detail` (the background activity panel).
/// Clients use it to decide whether to show the panel's chip.
const FEATURE_TASKS: &str = "tasks";

/// The optional capability advertised in `Welcome.features`: this daemon can hold
/// a permission request for the Mac app and takes its answer (`approval_*`).
const FEATURE_APPROVALS: &str = "approvals_v1";

/// The refusal a `ClaudeLoginAction` from anyone but the verified Mac app gets. No content.
const NOT_OPERATOR_APP_LOGIN: &str =
    "not_operator_app: only the verified Nostromo app may resend or discard a held message";

/// What `SessionAnswerPermission` is answered with, from every peer.
const ANSWER_PERMISSION_SUPERSEDED: &str = "session_answer_permission is superseded by approval_answer";

/// Latest broadcast frame per retain key (see [`retain_key`]), replayed to a
/// local client that subscribes after the frame was sent.
type RetainedCache = Arc<Mutex<BTreeMap<String, ServerMsg>>>;

/// The ids of the Mother jobs that, in the latest job list the daemon broadcast, are held with an
/// open structured decision. Only an id is kept, never job content.
type HeldMotherJobs = Arc<Mutex<HashSet<String>>>;

/// What a client is told when it sends a `PerriAction` while Perri is switched off.
const PERRI_DISABLED: &str = "Perri is disabled in this daemon's config ([agents.perri] enabled = false).";

/// What a local peer that is not the operator's app is told when it tries to answer a held job.
const MOTHER_HOLD_NEEDS_OPERATOR: &str = "This Mother hold needs the operator's choice in Nostromo's Mother panel.";

/// Handle to the running IPC server.  Drop to shut down.
pub struct Server {
    socket_path: PathBuf,
    pub tx: broadcast::Sender<ServerMsg>,
    retained: RetainedCache,
    held_mother_jobs: HeldMotherJobs,
    /// Bumped when the retained cache lagged and must be repopulated; the
    /// pollers that own retained frames (`fred`, `teri`) re-publish on it.
    republish: tokio::sync::watch::Sender<u64>,
}

impl Server {
    /// Bind a `UnixListener` at `socket_path`.
    ///
    /// `session_mgr` is shared with every client handler for persistent-session
    /// command routing.
    ///
    /// `perri_state_dir` is forwarded to the `PerriAction` handler so the
    /// `"approve"` arm can write the Phase 1 approval signal (approvals.jsonl +
    /// queue.dirty) for instant queue suppression.
    ///
    /// `decisions` is the shared decision-modal registry (W6) — also handed to
    /// `DaemonMcpBackend` so `nostromo.ask_decision` and this IPC layer share
    /// one source of truth for outstanding requests and `Topic::Decision`
    /// subscribers.
    ///
    /// `verifier` resolves the process behind each Unix connection, and
    /// `qa_mode` (`NOSTROMO_QA_DAEMON=1`) also accepts the QA instance's bundle
    /// id; together with the `Hello` they decide whether a connection is the
    /// operator app (see [`classify_peer`]).
    #[allow(clippy::too_many_arguments)]
    pub fn bind(
        socket_path: &Path,
        session_mgr: Arc<Mutex<SessionManager>>,
        perri_state_dir: PathBuf,
        decisions: Arc<Mutex<DecisionRegistry>>,
        verifier: Arc<dyn PeerVerifier>,
        qa_mode: bool,
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

        // The approval broker, if the daemon has one, broadcasts its frames on this channel.
        if let Some(broker) = session_mgr.lock().unwrap().approvals() {
            broker.configure_broadcast(tx.clone());
        }

        // Likewise the Claude sign-in coordinator, which tells clients which sessions wait.
        if let Some(login) = session_mgr.lock().unwrap().login() {
            login.configure_broadcast(tx.clone());
        }

        // Subscribe before returning so no broadcast sent after `bind` can be missed.
        let retained: RetainedCache = Arc::new(Mutex::new(BTreeMap::new()));
        let (republish, _) = tokio::sync::watch::channel(0u64);
        tokio::spawn(retain_broadcasts(tx.subscribe(), Arc::clone(&retained), republish.clone()));
        let held_mother_jobs: HeldMotherJobs = Arc::new(Mutex::new(HashSet::new()));
        tokio::spawn(track_held_mother_jobs(tx.subscribe(), Arc::clone(&held_mother_jobs)));

        let retained_for_loop = Arc::clone(&retained);
        let held_for_loop = Arc::clone(&held_mother_jobs);
        let unix_peers = UnixPeers { verifier, qa_mode };
        tokio::spawn(async move {
            if let Err(e) = accept_loop(listener, unix_peers, tx_clone, session_mgr, perri_state_dir, decisions, retained_for_loop, held_for_loop).await {
                warn!("IPC accept loop exited: {e:#}");
            }
        });

        info!(socket = %socket_path.display(), "IPC server listening");

        Ok(Self {
            socket_path: path,
            tx,
            retained,
            held_mother_jobs,
            republish,
        })
    }

    /// A receiver that changes whenever the retained-frame cache lagged and
    /// every source that owns a retained frame should publish its current
    /// state again. Pollers `select!` on `changed()` next to their own source.
    pub fn subscribe_republish(&self) -> tokio::sync::watch::Receiver<u64> {
        self.republish.subscribe()
    }

    /// Broadcast a message to all connected, subscribed clients.
    pub fn broadcast(&self, msg: ServerMsg) {
        let _ = self.tx.send(msg);
    }

    /// Attach a TCP listener that shares the same broadcast channel and
    /// session manager as the Unix socket listener.
    ///
    /// Both transports run the identical `handle_client` handshake loop, so iOS
    /// (and any other TCP peer) behaves exactly like the macOS TUI client.
    ///
    /// `perri_state_dir` and `decisions` are forwarded identically to
    /// [`Server::bind`].
    pub fn bind_tcp(
        &self,
        listener: TcpListener,
        session_mgr: Arc<Mutex<SessionManager>>,
        perri_state_dir: PathBuf,
        decisions: Arc<Mutex<DecisionRegistry>>,
    ) {
        let tx = self.tx.clone();
        let retained = Arc::clone(&self.retained);
        let held = Arc::clone(&self.held_mother_jobs);
        tokio::spawn(async move {
            if let Err(e) = accept_loop_tcp(listener, tx, session_mgr, perri_state_dir, decisions, retained, held).await {
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

/// How the Unix accept loop identifies its peers.
#[derive(Clone)]
struct UnixPeers {
    verifier: Arc<dyn PeerVerifier>,
    qa_mode: bool,
}

/// Who a connection is. A Unix peer is resolved by the verifier after its
/// `Hello` (see [`PeerOrigin::resolve`]), and again for every `DecisionAnswer`
/// (see [`PeerOrigin::still_the_operator`]).
enum PeerOrigin {
    Unix {
        verifier: Arc<dyn PeerVerifier>,
        /// A dup of the accepted socket, so the verifier can look at the peer
        /// again at answer time while the stream itself is split and owned by
        /// the read and write halves.
        fd: Arc<OwnedFd>,
        qa_mode: bool,
        /// What the verifier resolved after the `Hello`.
        info: Option<PeerInfo>,
    },
    Tcp,
}

impl PeerOrigin {
    /// Settle the connection's trust from the peer and its `Hello` claim. The
    /// verifier runs off the async workers (it is synchronous, and a slow one
    /// must not hold up other connections), and runs the code-signing check
    /// only when the `Hello` claims to be the Mac app.
    async fn resolve(&mut self, client_kind: Option<&str>) -> PeerTrust {
        match self {
            PeerOrigin::Unix { verifier, fd, qa_mode, info } => {
                let verify_code = client_kind == Some(MAC_APP_CLIENT_KIND);
                let (verifier, peer_fd) = (Arc::clone(verifier), Arc::clone(fd));
                *info = match tokio::task::spawn_blocking(move || verifier.inspect(peer_fd.as_fd(), verify_code)).await {
                    Ok(resolved) => resolved,
                    Err(e) => {
                        warn!("peer lookup failed: {e}");
                        None
                    }
                };
                classify_peer(info.as_ref(), client_kind, *qa_mode)
            }
            PeerOrigin::Tcp => PeerTrust::from_transport(Transport::Tcp),
        }
    }

    fn info(&self) -> Option<&PeerInfo> {
        match self {
            PeerOrigin::Unix { info, .. } => info.as_ref(),
            PeerOrigin::Tcp => None,
        }
    }

    /// Re-inspect the peer now, after a `DecisionAnswer` frame was read, and
    /// check it is still the very process verified at `Hello`
    /// ([`still_same_operator`]). `Err` names what failed; any failure refuses.
    async fn still_the_operator(&self) -> Result<(), String> {
        let PeerOrigin::Unix { verifier, fd, info: Some(accepted), .. } = self else {
            return Err("DecisionAnswer refused: no verified peer to re-check".to_string());
        };
        let (verifier, peer_fd, was) = (Arc::clone(verifier), Arc::clone(fd), accepted.clone());
        let now = tokio::task::spawn_blocking(move || verifier.reinspect(peer_fd.as_fd(), &was))
            .await
            .map_err(|e| format!("DecisionAnswer refused: answer-time re-inspection failed: {e}"))?;
        if still_same_operator(accepted, now.as_ref()) {
            return Ok(());
        }
        Err(match now {
            None => "DecisionAnswer refused: answer-time re-inspection could not identify the peer".to_string(),
            Some(now) => format!(
                "DecisionAnswer refused: the peer is no longer the process verified at Hello \
                 (pid {} -> {}, pidversion {} -> {}, code {:?})",
                accepted.pid, now.pid, accepted.pidversion, now.pidversion, now.code
            ),
        })
    }
}

/// A fresh per-connection operator nonce: 64 hex digits, two v4 UUIDs' worth
/// (244 bits) from the OS CSPRNG (`uuid` draws v4 ids from `getrandom`).
fn new_operator_nonce() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

/// Constant-time equality, so a wrong nonce's timing says nothing about how
/// much of it was right.
fn nonce_matches(expected: &str, got: &str) -> bool {
    let (a, b) = (expected.as_bytes(), got.as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// May this connection's `DecisionAnswer` be applied? Only for the operator
/// app, and only when the frame echoes the connection's nonce **and** the peer,
/// inspected again now, is still the process verified at `Hello`. The nonce is
/// checked first, so a frame without it never costs a re-inspection.
async fn check_operator_answer(
    origin: &PeerOrigin,
    issued: Option<&str>,
    sent: Option<&str>,
) -> Result<(), String> {
    let Some(sent) = sent else {
        return Err(
            "DecisionAnswer without operator nonce: app older than daemon? reinstall app and daemon together"
                .to_string(),
        );
    };
    if !issued.is_some_and(|issued| nonce_matches(issued, sent)) {
        return Err("DecisionAnswer refused: wrong operator nonce".to_string());
    }
    origin.still_the_operator().await
}

#[allow(clippy::too_many_arguments)]
async fn accept_loop(
    listener: UnixListener,
    peers: UnixPeers,
    tx: broadcast::Sender<ServerMsg>,
    session_mgr: Arc<Mutex<SessionManager>>,
    perri_state_dir: PathBuf,
    decisions: Arc<Mutex<DecisionRegistry>>,
    retained: RetainedCache,
    held_mother_jobs: HeldMotherJobs,
) -> Result<()> {
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let rx = tx.subscribe();
                let session_mgr = Arc::clone(&session_mgr);
                let broadcast_tx = tx.clone();
                let psd = perri_state_dir.clone();
                let decisions = Arc::clone(&decisions);
                let retained = Arc::clone(&retained);
                let held = Arc::clone(&held_mother_jobs);
                let peers = peers.clone();
                tokio::spawn(async move {
                    // Keep a dup of the socket for the verifier: the stream
                    // itself moves into the handler and is split there.
                    let fd = match stream.as_fd().try_clone_to_owned() {
                        Ok(fd) => Arc::new(fd),
                        Err(e) => {
                            warn!("cannot duplicate the peer socket: {e}");
                            return;
                        }
                    };
                    let origin = PeerOrigin::Unix { verifier: peers.verifier, fd, qa_mode: peers.qa_mode, info: None };
                    if let Err(e) = handle_client(stream, origin, rx, broadcast_tx, session_mgr, psd, decisions, retained, held).await {
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
    session_mgr: Arc<Mutex<SessionManager>>,
    perri_state_dir: PathBuf,
    decisions: Arc<Mutex<DecisionRegistry>>,
    retained: RetainedCache,
    held_mother_jobs: HeldMotherJobs,
) -> Result<()> {
    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                info!(%addr, "TCP IPC client connected");
                let rx = tx.subscribe();
                let session_mgr = Arc::clone(&session_mgr);
                let broadcast_tx = tx.clone();
                let psd = perri_state_dir.clone();
                let decisions = Arc::clone(&decisions);
                let retained = Arc::clone(&retained);
                let held = Arc::clone(&held_mother_jobs);
                tokio::spawn(async move {
                    if let Err(e) = handle_client(stream, PeerOrigin::Tcp, rx, broadcast_tx, session_mgr, psd, decisions, retained, held).await {
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

/// The `Welcome` frame for a connection: protocol version, advertised
/// features, the operator nonce (when the peer was verified) and the built-in
/// agents this daemon runs.
fn welcome_msg(mgr: &SessionManager, operator_nonce: Option<String>) -> ServerMsg {
    ServerMsg::Welcome {
        protocol_version: PROTOCOL_VERSION,
        daemon_pid: std::process::id(),
        features: vec![
            FEATURE_WORK.to_string(),
            FEATURE_MODEL.to_string(),
            FEATURE_TASKS.to_string(),
            FEATURE_APPROVALS.to_string(),
            FEATURE_LOGIN.to_string(),
        ],
        operator_nonce,
        enabled_agents: Some(mgr.enabled_agents().wire_names()),
        disabled_agents: Some(mgr.enabled_agents().disabled_names()),
    }
}

/// Handle a single connected client over any async transport (Unix socket, TCP, …).
///
/// The caller provides a stream that implements both [`AsyncRead`] and
/// [`AsyncWrite`].  `tokio::io::split` provides transport-agnostic halves
/// whose `ReadHalf`/`WriteHalf` are always `Unpin`, so the handshake and
/// the `select!` loop below need no stream-specific code.
///
/// `origin` is the transport and, for a Unix peer, what the verifier resolved
/// about it. The connection's [`PeerTrust`] is settled from it and the `Hello`.
/// A network peer is never sent Teri/Fred data and its requests for it are
/// refused; see [`super::peer`]. Only the operator app may answer a decision.
#[allow(clippy::too_many_arguments)]
async fn handle_client<S>(
    stream: S,
    mut origin: PeerOrigin,
    mut broadcast_rx: broadcast::Receiver<ServerMsg>,
    broadcast_tx: broadcast::Sender<ServerMsg>,
    session_mgr: Arc<Mutex<SessionManager>>,
    perri_state_dir: PathBuf,
    decisions: Arc<Mutex<DecisionRegistry>>,
    retained: RetainedCache,
    held_mother_jobs: HeldMotherJobs,
) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Send + 'static,
{
    let (mut reader, mut writer) = tokio::io::split(stream);

    // ── Handshake ─────────────────────────────────────────────────────────────

    let hello_bytes = read_frame(&mut reader).await?;
    let hello: ClientMsg = serde_json::from_slice(&hello_bytes)?;

    // `claimed_id` is what the client sent; used only for log context.
    // `conn_key` is a server-minted UUID used as the registry routing key so
    // that a malicious client cannot hijack another connection's targeted
    // channel by sending a pre-known client_id.
    let (claimed_id, conn_key, client_kind) = match hello {
        ClientMsg::Hello {
            ref client_id,
            protocol_version,
            ref client_kind,
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
            (client_id.clone(), Uuid::new_v4().to_string(), client_kind.clone())
        }
        _ => {
            let kind = frame_type(&hello_bytes);
            let err = ServerMsg::Error {
                message: format!("expected Hello, got a {kind} frame"),
            };
            let _ = write_frame(&mut writer, &serde_json::to_vec(&err)?).await;
            anyhow::bail!("unexpected first message: a {kind} frame");
        }
    };

    let trust = origin.resolve(client_kind.as_deref()).await;
    // Issued only once the peer is verified as the operator app, and required
    // in every `DecisionAnswer`: bytes written before verification (say, by a
    // process that then `exec`s the app) cannot contain it.
    let operator_nonce = (trust == PeerTrust::OperatorApp).then(new_operator_nonce);

    let welcome = welcome_msg(&session_mgr.lock().unwrap(), operator_nonce.clone());
    write_frame(&mut writer, &serde_json::to_vec(&welcome)?).await?;
    // Never log the nonce.
    let peer_pid = origin.info().map(|i| i.pid);
    let peer_exe = origin.info().map(|i| i.exe.display().to_string());
    if trust == PeerTrust::OperatorApp {
        info!(claimed_id, conn_key, ?trust, peer_pid, peer_exe, "operator app welcomed");
    } else if let Some(note) = claim_diagnostic(origin.info(), client_kind.as_deref(), trust) {
        warn!(claimed_id, conn_key, ?trust, peer_pid, peer_exe, "{note}");
    } else {
        debug!(claimed_id, conn_key, ?trust, peer_pid, peer_exe, "client welcomed");
    }

    // ── Subscribe ─────────────────────────────────────────────────────────────

    let sub_bytes = read_frame(&mut reader).await?;
    let sub: ClientMsg = serde_json::from_slice(&sub_bytes)?;

    let (mut topics, renders_decisions, renders_approvals): (Vec<Topic>, bool, bool) = match sub {
        ClientMsg::Subscribe { topics, renders_decisions, renders_approvals } => {
            (topics, renders_decisions, renders_approvals)
        }
        ClientMsg::Ping => {
            write_frame(&mut writer, &serde_json::to_vec(&ServerMsg::Pong)?).await?;
            (vec![], false, false)
        }
        _ => {
            // The frame's type only: its content is never logged.
            anyhow::bail!("expected Subscribe, got a {} frame", frame_type(&sub_bytes));
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
    //
    // And only the verified Mac app counts (AP1): it is the only peer whose
    // answer is accepted. Any other local peer, or a network peer, still
    // receives decisions it subscribed to, but someone who can't answer must
    // not keep `ask_decision` from failing fast with `no_operator`.
    let can_answer = trust == PeerTrust::OperatorApp;
    let mut is_operator = can_answer && (topics.contains(&Topic::Decision) || renders_decisions);
    if is_operator {
        decisions.lock().unwrap().add_operator(&conn_key);
    }

    // ── Approval presenters (AP0b) ────────────────────────────────────────────
    // Only the verified Mac app that says it renders approvals is a presenter: the
    // one kind of connection a permission request is held for, shown to, and
    // answered by. Tracked apart from decision operators.
    let broker = session_mgr.lock().unwrap().approvals().cloned();
    if can_answer {
        if let Some(broker) = &broker {
            broker.app_connected(&conn_key);
        }
    }
    let mut presents_approvals = false;
    let mut approvals_replay: Vec<ServerMsg> = Vec::new();
    if can_answer && renders_approvals {
        if let Some(broker) = &broker {
            presents_approvals = true;
            approvals_replay.push(ServerMsg::ApprovalsSnapshot { requests: broker.presenter_connected(&conn_key) });
        }
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
        // The session manager keeps its own client-sender registry for session
        // attach fan-out.
        let mgr = session_mgr.lock().unwrap();
        let registry = mgr.client_sender_registry();
        let mut senders = registry.lock().unwrap();
        senders.insert(conn_key.clone(), targeted_tx.clone());
    }

    // The requests already held, for a connection that just became a presenter
    // (registered above, so one held from here on is also broadcast to it; the
    // app dedupes by request id).
    replay_messages(&mut writer, std::mem::take(&mut approvals_replay)).await;

    // ── Claude sign-in replay — who is waiting for one, as of now ─────────────
    // The whole picture (REPLACE semantics), so a client that connects while a
    // session waits shows it at once. `LocalOnly`: a network peer is sent none.
    if !trust.is_network() {
        let snapshot = session_mgr.lock().unwrap().login_snapshot();
        replay_messages(&mut writer, [snapshot]).await;
    }

    // ── Layout replay — push existing pane trees to newly subscribed client ──
    // A freshly connected or reconnected client would otherwise see empty panes
    // until the agent next sends a structural mutation. Replay one FocusLayout
    // per registered focus so the client starts with a complete picture.
    // `focused_pane` is omitted (None) — the registry does not persist it;
    // the client re-establishes it.
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

    // ── Tracker replay — each bound focus's board and summary ─────────────────
    // Not behind a topic (like the task frames): a client that never heard of
    // trackers ignores the type. A network peer is replayed only the summary
    // of a non-sensitive focus; the board frame is `LocalOnly`.
    {
        // Clone the handle and drop the manager lock before calling into it.
        let provider = session_mgr.lock().unwrap().tracker_frame_provider();
        if let Some(provider) = provider {
            replay_messages(
                &mut writer,
                provider
                    .tracker_frames()
                    .into_iter()
                    .filter_map(|m| outbound(trust, m, &sensitive)),
            )
            .await;
        }
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

    // ── Model replay — catalogue, defaults and every focus's model state ──────
    // Every peer: a network peer is withheld the state of a sensitive focus by
    // the same filter as that focus's transcript.
    if wants_model(&topics) {
        let frames = model_replay(&session_mgr);
        replay_messages(&mut writer, frames.into_iter().filter_map(|m| outbound(trust, m, &sensitive)))
            .await;
    }

    // ── Main loop (broadcast + targeted + client reads) ───────────────────────

    // `read_frame` is not cancel-safe (a frame is a header read then a body
    // read), and the `select!` below drops whichever branch loses. Reading in
    // a task of its own and receiving whole frames here means a broadcast
    // arriving mid-frame cannot drop half a frame and desync the stream.
    let (frame_tx, mut frames) = mpsc::channel::<Result<Vec<u8>>>(16);
    let reader_task = tokio::spawn(async move {
        loop {
            let frame = read_frame(&mut reader).await;
            let failed = frame.is_err();
            if frame_tx.send(frame).await.is_err() || failed {
                break;
            }
        }
    });

    let result: Result<()> = loop {
        tokio::select! {
            // Broadcast events (activity, Mother, etc.)
            bcast = broadcast_rx.recv() => {
                match bcast {
                    Ok(msg) => {
                        // Trust gate first: a network peer never gets a
                        // sensitive frame, whatever its topic list says.
                        if !deliver_broadcast(&msg, &topics, presents_approvals) {
                            continue;
                        }
                        let Some(msg) = outbound(trust, msg, &sensitive) else {
                            continue;
                        };
                        let bytes = match serde_json::to_vec(&msg) {
                            Ok(b) => b,
                            Err(e) => { warn!("serialise error: {e}"); continue; }
                        };
                        if write_outbound(&mut writer, &bytes, &conn_key).await.is_err() {
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

            // Targeted messages (session replies, refusals, errors).
            Some(msg) = targeted_rx.recv() => {
                // Targeted frames (session transcripts, replies, summaries)
                // go through the same gate as broadcasts; the only
                // sensitive frames a network peer gets are refusals.
                let Some(msg) = outbound(trust, msg, &sensitive) else {
                    continue;
                };
                let Some(msg) = without_notes_unless_model(msg, &topics) else {
                    continue;
                };
                let bytes = match serde_json::to_vec(&msg) {
                    Ok(b) => b,
                    Err(e) => { warn!("serialise targeted msg: {e}"); continue; }
                };
                if write_outbound(&mut writer, &bytes, &conn_key).await.is_err() {
                    break Ok(());
                }
            }

            // Commands from client
            frame = frames.recv() => {
                match frame.unwrap_or_else(|| Err(anyhow::anyhow!("reader task ended"))) {
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
                        if let ClientMsg::Subscribe { topics: new_topics, renders_decisions, renders_approvals } = msg {
                            if can_answer && !is_operator && (new_topics.contains(&Topic::Decision) || renders_decisions) {
                                decisions.lock().unwrap().add_operator(&conn_key);
                                is_operator = true;
                            }
                            // A resubscribe that claims it renders approvals makes the
                            // verified app a presenter (and replays what is held); it
                            // stays one until the connection ends.
                            if can_answer && renders_approvals && !presents_approvals {
                                if let Some(broker) = &broker {
                                    presents_approvals = true;
                                    let requests = broker.presenter_connected(&conn_key);
                                    replay_messages(&mut writer, [ServerMsg::ApprovalsSnapshot { requests }]).await;
                                }
                            } else if presents_approvals && !renders_approvals {
                                // Resubscribing without it gives the status up.
                                presents_approvals = false;
                                if let Some(broker) = &broker {
                                    broker.presenter_revoked(&conn_key);
                                }
                            }
                            // Replay retained frames only for the topics this
                            // subscribe adds; a network peer gets none.
                            let mut frames = if trust.is_network() {
                                vec![]
                            } else {
                                retained_matching(&retained, &new_topics, Some(&topics))
                            };
                            if wants_model(&new_topics) && !wants_model(&topics) {
                                frames.extend(
                                    model_replay(&session_mgr)
                                        .into_iter()
                                        .filter_map(|m| outbound(trust, m, &sensitive)),
                                );
                            }
                            topics = new_topics;
                            replay_messages(&mut writer, frames).await;
                            continue;
                        }
                        // A `DecisionAnswer` from the operator app is checked
                        // here, where awaiting is possible: the nonce, then a
                        // fresh look at the peer. The dispatch below applies it
                        // only on `Some(Ok(()))`.
                        let answer_check = match &msg {
                            ClientMsg::DecisionAnswer { operator_nonce: sent, .. }
                            | ClientMsg::ApprovalAnswer { operator_nonce: sent, .. }
                            | ClientMsg::ClaudeLoginAction { operator_nonce: sent, .. }
                                if trust == PeerTrust::OperatorApp =>
                            {
                                Some(check_operator_answer(&origin, operator_nonce.as_deref(), sent.as_deref()).await)
                            }
                            _ => None,
                        };
                        handle_client_msg(msg, trust, origin.info(), answer_check, &sensitive, &conn_key, &claimed_id, &session_mgr, &targeted_tx, &broadcast_tx, &perri_state_dir, &decisions, &held_mother_jobs);
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

    reader_task.abort();
    debug!(
        claimed_id,
        conn_key,
        "client handler exiting; detaching sessions"
    );
    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.on_client_disconnect(&conn_key);
    }
    if is_operator {
        decisions.lock().unwrap().remove_operator(&conn_key);
    }
    if let Some(broker) = &broker {
        broker.app_disconnected(&conn_key);
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
            let _ = write_outbound(writer, &bytes, "replay").await;
        }
    }
}

/// A client-supplied string made safe to put in a log line: no newlines or
/// invisible characters, and bounded.
fn log_safe(s: &str) -> String {
    let clean = crate::approvals::audit::sanitize_string(s);
    let mut out: String = clean.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    if out.len() > 256 {
        let mut cut = 256;
        while !out.is_char_boundary(cut) {
            cut -= 1;
        }
        out.truncate(cut);
    }
    out
}

/// The `type` of a client frame, safe to log; never its content.
fn frame_type(bytes: &[u8]) -> String {
    serde_json::from_slice::<serde_json::Value>(bytes)
        .ok()
        .and_then(|v| v.get("type").and_then(|t| t.as_str().map(log_safe)))
        .unwrap_or_else(|| "unreadable".to_owned())
}

/// Write one server frame. A frame over [`MAX_FRAME_LEN`] cannot be carried:
/// it is dropped with a warning and the connection stays up. (Treating it as a
/// write failure would close the connection, and the client would reconnect
/// and be replayed the same retained frame.) `Err` means the socket itself failed.
async fn write_outbound<W>(writer: &mut W, bytes: &[u8], conn: &str) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    if bytes.len() > MAX_FRAME_LEN {
        warn!(conn, len = bytes.len(), max = MAX_FRAME_LEN, "dropping an oversized server frame");
        return Ok(());
    }
    write_frame(writer, bytes).await
}

// ── client command dispatch ──────────────────────────────────────────────────────

/// `conn_key` is the server-minted UUID for this connection (not the
/// client-supplied `client_id` from the Hello frame, which is `client_id`:
/// identification for "select this focus in that client", never a credential).
///
/// Eight shared-state handles, one per subsystem this dispatch touches —
/// matches the existing precedent on `McpSharedState::new` (ten arguments,
/// same allowance) rather than introducing a bundling struct for a single
/// internal dispatch function.
#[allow(clippy::too_many_arguments)]
fn handle_client_msg(
    msg: ClientMsg,
    trust: PeerTrust,
    peer: Option<&PeerInfo>,
    answer_check: Option<Result<(), String>>,
    sensitive: &SensitiveTags,
    conn_key: &str,
    client_id: &str,
    session_mgr: &Arc<Mutex<SessionManager>>,
    targeted_tx: &mpsc::UnboundedSender<ServerMsg>,
    broadcast_tx: &broadcast::Sender<ServerMsg>,
    perri_state_dir: &Path,
    decisions: &Arc<Mutex<DecisionRegistry>>,
    held_mother_jobs: &HeldMotherJobs,
) {
    // Default-deny for network peers (see `peer::refuse_for_network`): anything
    // but an explicitly allowed read-only request changes nothing.
    if trust.is_network() && refuse_for_network(&msg, sensitive) {
        log_network_model_refusal(&msg, session_mgr, sensitive);
        log_network_task_refusal(&msg, session_mgr, sensitive);
        // An attempt to answer a permission request over the network is a
        // security event: it is logged before the peer is told no.
        if let ClientMsg::ApprovalAnswer { request_id, .. } = &msg {
            refuse_approval_answer(
                session_mgr.lock().unwrap().approvals().cloned(),
                targeted_tx,
                request_id.clone(),
                AnswerRefusal::RequiresSecureConnection,
                network_refusal_reply(&msg),
                peer_json(trust, peer),
            );
            return;
        }
        refuse_over_network(&msg, targeted_tx);
        return;
    }

    match msg {
        ClientMsg::Ping => {
            let _ = targeted_tx.send(ServerMsg::Pong);
        }

        // Retired (R2): the daemon no longer hosts PTYs. The verbs still decode
        // (FND-1 ordinals stay stable) and are answered with a clear error.
        ClientMsg::PtySpawn { .. }
        | ClientMsg::PtyAttach { .. }
        | ClientMsg::PtyDetach { .. }
        | ClientMsg::PtyInput { .. }
        | ClientMsg::PtyResize { .. }
        | ClientMsg::PtyKill { .. }
        | ClientMsg::PtyList => {
            let _ = targeted_tx.send(ServerMsg::Error { message: PTY_HOST_REMOVED.to_owned() });
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
            let (result, registry) = {
                let mut mgr = session_mgr.lock().unwrap();
                let result = mgr.spawn_session(
                    tag.clone(),
                    agent_name,
                    view_name,
                    cwd,
                    session_id,
                    remote_control,
                );
                (result, mgr.pane_registry())
            };
            match result {
                Ok(session_id) => {
                    // A fresh spawn re-seeds the layout (`init_focus`), which for a
                    // focus that owns a native pane, or keeps its tracker pane,
                    // replaces the tree a window may still hold. Tell every client
                    // the tree the daemon now has.
                    let tree = registry.and_then(|reg| reg.lock().unwrap().get(&tag).cloned());
                    if let Some(tree) = tree.filter(|tree| {
                        crate::mcp::views::tree::native_pane_for(&tag).is_some()
                            || crate::tracker::placement::has_tracker(tree)
                    }) {
                        let _ = broadcast_tx.send(ServerMsg::FocusLayout {
                            tag: tag.clone(),
                            tree,
                            focused_pane: None,
                        });
                    }
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
                if trust.is_network() {
                    mgr.attach_network(&tag, conn_key)
                } else {
                    mgr.attach(&tag, conn_key)
                }
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
            // A network peer never reaches here (`session_send` is refused for
            // it, see `peer::refused_for_network`). Kept as defense in
            // depth: if a network peer ever can write, withdraw the session's
            // Teri/Fred/Mother tools first. (Only a live session can be
            // written to, which also bounds how many tags this records.)
            if trust.is_network() && mgr.has_live_session(&tag) {
                sensitive.mark_network_driven(&tag);
            }
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
            match mgr.interrupt(&tag) {
                Ok(crate::ipc::session_manager::InterruptOutcome::DiscardedHold) => {
                    // Said without content: what was held is gone, and nothing is sent after the sign-in.
                    let _ = targeted_tx.send(ServerMsg::Notification {
                        tag: tag.clone(),
                        level: crate::ipc::protocol::NotificationLevel::Info,
                        message: "Stopped: the message waiting for sign-in was discarded.".to_string(),
                    });
                }
                Ok(_) => {}
                Err(e) => {
                    warn!(conn_key, %tag, "SessionInterrupt error: {e}");
                    let _ = targeted_tx.send(ServerMsg::Error {
                        message: format!("SessionInterrupt failed: {e}"),
                    });
                }
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
            // Superseded by `ApprovalAnswer` (AP0b): refused for every peer, with
            // no side effect.
            debug!(conn_key, %tag, "SessionAnswerPermission refused: superseded by approval_answer");
            let _ = targeted_tx.send(ServerMsg::Error { message: ANSWER_PERMISSION_SUPERSEDED.to_string() });
        }

        ClientMsg::ApprovalAnswer { request_id, decision, window_id, .. } => {
            let broker = session_mgr.lock().unwrap().approvals().cloned();
            let refused = |code: AnswerRefusal| ServerMsg::ApprovalAnswerRefused {
                request_id: request_id.clone(),
                code,
                outcome: None,
            };
            // Only the verified Mac app answers for the human, and only with the
            // connection's nonce from a process still verified (checked by the
            // caller). Anything else changes nothing and is logged.
            let not_allowed = if trust != PeerTrust::OperatorApp {
                Some("not the verified Nostromo app".to_string())
            } else {
                match answer_check {
                    Some(Ok(())) => None,
                    Some(Err(why)) => Some(why),
                    None => Some("ApprovalAnswer refused: not checked".to_string()),
                }
            };
            if let Some(why) = not_allowed {
                let logged_id = log_safe(&request_id);
                warn!(conn_key, request_id = %logged_id, ?trust, peer_pid = peer.map(|p| p.pid), "ApprovalAnswer refused: {why}");
                let reply = refused(AnswerRefusal::NotOperatorApp);
                refuse_approval_answer(
                    broker,
                    targeted_tx,
                    request_id,
                    AnswerRefusal::NotOperatorApp,
                    reply,
                    peer_json(trust, peer),
                );
                return;
            }
            let Some(broker) = broker else {
                let _ = targeted_tx.send(refused(AnswerRefusal::UnknownRequest));
                return;
            };
            // Writing the answer to the session and the audit log is blocking I/O.
            let (tx, conn, peer) = (targeted_tx.clone(), conn_key.to_string(), peer_json(trust, peer));
            tokio::task::spawn_blocking(move || {
                // Applied: the resolution is broadcast to every presenter, this one included.
                if let Some(refusal) = broker.answer_or_refusal(&request_id, &decision, &window_id, &conn, peer) {
                    let _ = tx.send(refusal);
                }
            });
        }

        ClientMsg::ClaudeLoginAction { action, tag, hold_id, .. } => {
            // Only the verified Mac app resends or drops a held message, and only with
            // the connection's nonce from a process still verified (checked by the
            // caller). Anything else changes nothing and is told, with no content.
            let refusal = if trust != PeerTrust::OperatorApp {
                Some("not the verified Nostromo app".to_string())
            } else {
                match answer_check {
                    Some(Ok(())) => None,
                    Some(Err(why)) => Some(why),
                    None => Some("ClaudeLoginAction refused: not checked".to_string()),
                }
            };
            if let Some(why) = refusal {
                debug!(conn_key, ?trust, peer_pid = peer.map(|p| p.pid), "ClaudeLoginAction refused: {why}");
                let _ = targeted_tx.send(ServerMsg::Error { message: NOT_OPERATOR_APP_LOGIN.to_string() });
                return;
            }
            let mut mgr = session_mgr.lock().unwrap();
            match (action, hold_id) {
                (ClaudeLoginActionKind::Retry, Some(hold_id)) => {
                    mgr.resend_held(&tag, &hold_id, ResendTrigger::Manual);
                }
                // Nothing is held to send again; the sender learns where things stand.
                (ClaudeLoginActionKind::Retry, None) => {
                    if let Some(login) = mgr.login() {
                        login.rebroadcast();
                    }
                }
                (ClaudeLoginActionKind::Discard, hold_id) => {
                    mgr.discard_held(&tag, hold_id.as_deref());
                }
            }
        }

        ClientMsg::ApprovalRefusalReport { request_id, control, channel } => {
            if trust != PeerTrust::OperatorApp {
                debug!(conn_key, ?trust, "ApprovalRefusalReport dropped: not the verified Nostromo app");
                return;
            }
            let broker = session_mgr.lock().unwrap().approvals().cloned();
            audit_refusal_then(
                broker,
                request_id,
                "synthetic_input_refused",
                peer_json(trust, peer),
                Some(channel),
                Some(control),
                || {},
            );
        }

        ClientMsg::SessionList => {
            let mgr = session_mgr.lock().unwrap();
            let sessions = mgr.list();
            let _ = targeted_tx.send(ServerMsg::SessionListResp { sessions });
        }

        ClientMsg::FocusRegistryPush { focuses } => {
            let (updated, departed, reconcilable, pane_registry) = {
                let mut mgr = session_mgr.lock().unwrap();
                // Defence in depth: `refuse_for_network` already turns a network
                // peer's push away before it gets here. Both of these act on what a
                // push says, so neither may ever run for a network peer: a model a
                // peer names would be an upgrade nobody approved.
                if !trust.is_network() {
                    mgr.mark_teri_fred_focuses(&focuses);
                    mgr.apply_initial_models(&focuses);
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
                        .or_else(|| reg.ensure_mother_layout(&focus.tag))
                        .or_else(|| reg.ensure_teri_layout(&focus.tag))
                        .or_else(|| reg.ensure_fred_layout(&focus.tag));
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
            // A structured hold is the operator's choice, made in Nostromo's Mother panel (the verified
            // app). Anything else on this machine is turned away, without a call to the `mother` CLI.
            // A job with no open decision resumes as before. (TCP peers never reach here: refused above.)
            if trust != PeerTrust::OperatorApp && held_mother_jobs.lock().unwrap().contains(&job_id) {
                warn!(conn_key, ?trust, "MotherResume refused: the job has an open decision");
                let _ = targeted_tx.send(ServerMsg::Error { message: MOTHER_HOLD_NEEDS_OPERATOR.to_owned() });
                return;
            }
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
            // A disabled Perri must not run `gh` or write its state files.
            // The refusal names no action, repo or PR.
            if !session_mgr.lock().unwrap().enabled_agents().is_enabled(crate::agents::Agent::Perri) {
                warn!(conn_key, "PerriAction refused: perri is disabled");
                let _ = targeted_tx.send(ServerMsg::Error { message: PERRI_DISABLED.to_owned() });
                return;
            }
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

        ClientMsg::DecisionAnswer { request_id, choice_id, .. } => {
            // Only the verified Mac app answers for the human: an agent's own
            // script on this socket must not answer the agent's decision. The
            // request stays pending, untouched.
            if trust != PeerTrust::OperatorApp {
                warn!(
                    conn_key,
                    %request_id,
                    ?trust,
                    peer_pid = peer.map(|p| p.pid),
                    peer_exe = ?peer.map(|p| &p.exe),
                    "DecisionAnswer refused: not the verified Nostromo app"
                );
                let _ = targeted_tx.send(ServerMsg::Error { message: NOT_OPERATOR_APP.to_string() });
                return;
            }
            // The operator app, but this frame must also carry the
            // connection's nonce and come from the process verified at Hello
            // (`check_operator_answer`). Refused before the registry is
            // touched, so a refusal changes nothing.
            let refusal = match answer_check {
                Some(Ok(())) => None,
                Some(Err(why)) => Some(why),
                None => Some("DecisionAnswer refused: not checked".to_string()),
            };
            if let Some(why) = refusal {
                warn!(conn_key, %request_id, peer_pid = peer.map(|p| p.pid), "{why}");
                // A refusal never resolves the decision: the asking agent keeps
                // waiting until its own timeout (`timeout_secs`, default 300).
                // Say so once per decision, so the log explains the stall.
                if decisions.lock().unwrap().first_refusal(&request_id) {
                    warn!(
                        conn_key,
                        %request_id,
                        "decision stays pending (the agent waits until its timeout) because its answer was \
                         refused: {why}. Run make mac-install and relaunch the app, then ask again"
                    );
                }
                let _ = targeted_tx.send(ServerMsg::Error { message: NOT_OPERATOR_APP.to_string() });
                return;
            }
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
                AnswerOutcome::UnknownChoice => {
                    warn!(conn_key, %request_id, "DecisionAnswer named a choice the request did not offer");
                    let _ = targeted_tx.send(ServerMsg::Error {
                        message: "decision_answer: choice_id is not one of the offered choices".to_string(),
                    });
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
            instruction,
            allow_duplicate,
        } => {
            let tx = targeted_tx.clone();
            let request = SendRequest {
                request_id: request_id.clone(),
                item_id,
                destination,
                agent,
                working_directory,
                label,
                instruction,
                allow_duplicate,
                client_id: Some(client_id.to_owned()),
            };
            let sensitive = sensitive.clone();
            tokio::spawn(async move {
                // Inside the scope, the session manager registers every tag
                // the send spawns, seeds or announces *before* doing so, so
                // nothing it creates can reach a network peer before this
                // returns.
                let result = within_work_send(work_service().send(request)).await;
                // The send's outcome names what it created; registering it here
                // as well covers a service that did not go through the session
                // manager, and the Mother job (whose id is not known sooner). Until
                // then the job is withheld from a network peer by its
                // `teri-send` label (`MotherJob::is_work_send`).
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

        // ── model switching (mutations: local peers only; refused above) ───
        ClientMsg::ModelCatalogRequest {} => {
            let msg = session_mgr.lock().unwrap().model_hub().catalog_msg();
            let _ = targeted_tx.send(msg);
        }

        ClientMsg::ModelCatalogRefresh {} => {
            let hub = session_mgr.lock().unwrap().model_hub();
            tokio::spawn(async move {
                // The result (or the stale flag) is broadcast by the hub.
                let _ = crate::model::hub::refresh_catalog(&hub).await;
            });
        }

        ClientMsg::SessionModelGet { tag } => {
            let state = session_mgr.lock().unwrap().session_model_state(&tag);
            let _ = targeted_tx.send(ServerMsg::SessionModelState(state));
        }

        ClientMsg::SessionModelSet {
            tag,
            model,
            effort,
            set_as_agent_default,
            request_id,
            actor,
        } => {
            // Only a local peer gets here; it is the user unless it says it is
            // the app-control script.
            let request = SwitchRequest {
                model,
                effort,
                actor: crate::model::Actor::from_wire(actor.as_deref()),
                set_as_agent_default,
                request_id: Some(request_id.clone()),
            };
            let ticket = session_mgr.lock().unwrap().request_switch(&tag, request);
            let tx = targeted_tx.clone();
            tokio::spawn(async move {
                let outcome = ticket.outcome().await;
                let _ = tx.send(model_request_result(request_id, outcome));
            });
        }

        ClientMsg::ModelDefaultsRequest {} => {
            let msg = session_mgr.lock().unwrap().model_defaults_msg();
            let _ = targeted_tx.send(msg);
        }

        ClientMsg::ModelDefaultSet { agent, model, effort, clear, request_id } => {
            let outcome = session_mgr.lock().unwrap().set_agent_default(&agent, model, effort, clear);
            let _ = targeted_tx.send(model_request_result(request_id, outcome));
        }

        // ── background tasks (the verified app only; network refused above) ─
        // An agent's own script on this socket must not stop another focus's
        // task or read its output. Refused before the registry, a file or the
        // CLI is touched; the reply carries no task content.
        ClientMsg::SessionTaskStop { request_id, tag, task_id } if trust != PeerTrust::OperatorApp => {
            warn!(conn_key, ?trust, "SessionTaskStop refused: not the verified Nostromo app");
            let _ = targeted_tx.send(ServerMsg::SessionTaskStopResult {
                request_id,
                tag,
                task_id,
                outcome: crate::ipc::protocol::TaskStopOutcome::Refused,
                message: Some(NOT_OPERATOR_APP.to_string()),
            });
        }

        ClientMsg::SessionTaskOutput { request_id, tag, task_id, .. } if trust != PeerTrust::OperatorApp => {
            warn!(conn_key, ?trust, "SessionTaskOutput refused: not the verified Nostromo app");
            let _ = targeted_tx.send(ServerMsg::SessionTaskOutputResult {
                request_id,
                tag,
                task_id,
                outcome: crate::ipc::protocol::TaskOutputOutcome::Refused,
                text: String::new(),
                start_offset: 0,
                end_offset: 0,
                total_bytes: 0,
                source: None,
                message: Some(NOT_OPERATOR_APP.to_string()),
            });
        }

        ClientMsg::SessionTaskStop { request_id, tag, task_id } => {
            let stop = session_mgr.lock().unwrap().task_stop(&tag, &task_id);
            let audit_tag = audit_focus_tag(&tag, sensitive);
            let tx = targeted_tx.clone();
            tokio::spawn(async move {
                let report = stop.await;
                // The line is written before the client hears the outcome.
                log_task_stop(&report, audit_tag);
                let _ = tx.send(ServerMsg::SessionTaskStopResult {
                    request_id,
                    tag,
                    task_id,
                    outcome: report.outcome,
                    message: report.message,
                });
            });
        }

        ClientMsg::SessionTaskOutput { request_id, tag, task_id, offset, max_bytes } => {
            let read = session_mgr.lock().unwrap().task_output(&tag, &task_id, offset, max_bytes);
            let tx = targeted_tx.clone();
            tokio::spawn(async move {
                let reply = read.await;
                let _ = tx.send(ServerMsg::SessionTaskOutputResult {
                    request_id,
                    tag,
                    task_id,
                    outcome: reply.outcome,
                    text: reply.text,
                    start_offset: reply.start_offset,
                    end_offset: reply.end_offset,
                    total_bytes: reply.total_bytes,
                    source: reply.source,
                    message: reply.message,
                });
            });
        }

        // These are already handled during handshake; ignore duplicates.
        ClientMsg::Hello { .. } | ClientMsg::Subscribe { .. } => {}
    }
}

/// `tag` as an activity line may name it: a sensitive focus's tag can embed a
/// work item's title, so it is logged as its opaque id.
fn audit_focus_tag(tag: &str, sensitive: &SensitiveTags) -> String {
    if sensitive.tag_is_sensitive(tag) {
        sensitive.opaque_tag(tag)
    } else {
        tag.to_owned()
    }
}

/// Append the audit line for a stop the user asked for: actor, the focus,
/// the task's kind and description, and how it ended.
fn log_task_stop(report: &crate::ipc::session_manager::StopReport, focus_tag: String) {
    use crate::ipc::protocol::TaskStopOutcome as Stop;
    use crate::model::activity::{activity_path, append_task, Outcome, TaskActivity, TaskActivityKind};
    let (outcome, reason) = match report.outcome {
        Stop::Accepted => (Outcome::Applied, None),
        Stop::Refused => (Outcome::Refused, report.message.as_deref().map(bounded_reason)),
        Stop::NotRunning => (Outcome::Refused, Some("not_running".to_owned())),
        Stop::Timeout => (Outcome::Failed, Some("timeout".to_owned())),
        Stop::Unsupported => (Outcome::Failed, Some("unsupported".to_owned())),
    };
    let description = report.label.as_ref().map(|l| {
        crate::ipc::task_output::truncate_chars(&l.description, 200)
    });
    // The summary is what the activity stream shows: it names the kind of task,
    // never its description (a command line or a prompt).
    let what = report.label.as_ref().map_or("task", |l| l.kind.label());
    let agent = (!report.agent_name.is_empty()).then(|| report.agent_name.clone());
    append_task(
        &activity_path(),
        &TaskActivity {
            agent: agent.clone().unwrap_or_else(|| "claude".to_owned()),
            kind: TaskActivityKind::TaskStop,
            summary: format!("Stop of a {what}: {}.", outcome_word(outcome)),
            session_id: report.session_id.clone(),
            agent_type: agent,
            focus_tag: Some(focus_tag),
            actor: "user".to_owned(),
            task_kind: report.label.as_ref().map(|l| l.kind),
            description,
            outcome,
            reason,
        },
    );
}

/// The CLI's refusal text as an audit `reason`: control characters stripped,
/// at most 120 characters.
fn bounded_reason(text: &str) -> String {
    let clean: String = text.chars().filter(|c| !c.is_control()).collect();
    crate::ipc::task_output::truncate_chars(&clean, 120)
}

fn outcome_word(outcome: crate::model::activity::Outcome) -> &'static str {
    use crate::model::activity::Outcome;
    match outcome {
        Outcome::Applied => "applied",
        Outcome::Failed => "failed",
        Outcome::Denied => "denied",
        Outcome::Expired => "expired",
        Outcome::Refused => "refused",
    }
}

/// Does this client take model frames? Only by naming `Topic::Model`: unlike
/// other topics, the empty "everything" list does not include it, because a
/// client that predates model switching can't decode a transcript carrying a
/// `TurnBlock::Note` (it drops the whole `SessionTurns` frame).
fn wants_model(topics: &[Topic]) -> bool {
    topics.contains(&Topic::Model)
}

/// A session frame as a client that has not asked for model frames gets it:
/// without transcript notes (see [`wants_model`]).
fn without_notes_unless_model(msg: ServerMsg, topics: &[Topic]) -> Option<ServerMsg> {
    use crate::ipc::stream_json::{Turn, TurnBlock, TurnDelta};
    fn strip(turn: &mut Turn) {
        turn.blocks.retain(|b| !matches!(b, TurnBlock::Note { .. }));
    }
    if wants_model(topics) {
        return Some(msg);
    }
    match msg {
        ServerMsg::SessionTurns { tag, mut turns } => {
            turns.iter_mut().for_each(strip);
            Some(ServerMsg::SessionTurns { tag, turns })
        }
        ServerMsg::SessionTurnDelta { delta: TurnDelta::Note { .. }, .. } => None,
        ServerMsg::SessionTurnDelta { tag, delta: TurnDelta::TurnStarted { mut turn } } => {
            strip(&mut turn);
            Some(ServerMsg::SessionTurnDelta { tag, delta: TurnDelta::TurnStarted { turn } })
        }
        other => Some(other),
    }
}

/// What a client subscribing to `Topic::Model` is replayed: the catalogue,
/// the defaults and the model state of every focus the daemon knows.
fn model_replay(session_mgr: &Arc<Mutex<SessionManager>>) -> Vec<ServerMsg> {
    let mgr = session_mgr.lock().unwrap();
    let mut frames = vec![mgr.model_hub().catalog_msg(), mgr.model_defaults_msg()];
    frames.extend(mgr.model_state_replay().into_iter().map(ServerMsg::SessionModelState));
    frames
}

/// `ServerMsg::ModelRequestResult` for `outcome`.
fn model_request_result(request_id: String, outcome: ModelRequestOutcome) -> ServerMsg {
    ServerMsg::ModelRequestResult {
        request_id,
        status: outcome.status,
        code: outcome.code,
        message: outcome.message,
        warning: outcome.warning,
    }
}

/// A network peer's model mutation is refused with no side effect but one
/// `refused` activity line (the audit trail of who tried).
///
/// The peer is unauthenticated, so nothing it sent is written verbatim: the
/// focus tag only if it names a focus the daemon knows (a sensitive focus's
/// tag can embed a work item's title, so it is logged as its opaque id), the
/// agent only as that focus's own agent, the model only if the catalogue
/// offers it. Lines are rate-limited so a peer cannot flood the log.
fn log_network_model_refusal(
    msg: &ClientMsg,
    session_mgr: &Arc<Mutex<SessionManager>>,
    sensitive: &SensitiveTags,
) {
    use crate::model::activity::{activity_path, append, current_posture, ModelActivity, ModelActivityKind, Outcome};
    use crate::model::ModelTarget;
    let kind = match msg {
        ClientMsg::SessionModelSet { .. } => ModelActivityKind::ModelSwitch,
        ClientMsg::ModelDefaultSet { .. } => ModelActivityKind::ModelDefault,
        _ => return,
    };
    if !refusal_line_allowed() {
        return;
    }
    let (tag, agent, to) = {
        let mgr = session_mgr.lock().unwrap();
        let catalog = mgr.model_catalog();
        let offered = |model: &Option<String>, effort: &Option<crate::ipc::protocol::EffortChoice>| {
            model.as_ref().filter(|m| catalog.entry(m).is_some()).map(|m| ModelTarget {
                model: m.clone(),
                effort: effort.and_then(|e| e.level()).map(str::to_owned),
            })
        };
        match msg {
            ClientMsg::SessionModelSet { tag, model, effort, .. } => {
                let (tag, agent) = known_focus(&mgr, tag);
                (tag, agent, offered(model, effort))
            }
            ClientMsg::ModelDefaultSet { model, effort, .. } => (None, None, offered(model, effort)),
            _ => return,
        }
    };
    let tag = tag.map(|t| audit_focus_tag(&t, sensitive));
    let agent = agent.filter(|a| !a.is_empty()).unwrap_or_else(|| "claude".to_owned());
    append(
        &activity_path(),
        &ModelActivity {
            agent: agent.clone(),
            kind,
            summary: "Model change from a network client refused: requires a secure connection.".to_owned(),
            session_id: None,
            agent_type: Some(agent),
            focus_tag: tag,
            from: None,
            to,
            actor: "network".to_owned(),
            outcome: Outcome::Refused,
            reason: Some("requires_secure_connection".to_owned()),
            posture: current_posture(),
        },
    );
}

/// `tag` and its session's agent name, each only when the daemon knows the
/// focus: a network peer's tag is not written to the log otherwise.
fn known_focus(mgr: &SessionManager, tag: &str) -> (Option<String>, Option<String>) {
    let session = mgr.list().into_iter().find(|s| s.tag == tag);
    let known = session.is_some() || mgr.known_focus_tags().iter().any(|t| t == tag);
    (known.then(|| tag.to_owned()), session.map(|s| s.agent_name))
}

/// A network peer's task verb is refused with no side effect but one
/// `refused` activity line, rate-limited like the model one. Nothing the
/// unauthenticated peer sent is written: not the task id, and the focus tag
/// only if it names a focus the daemon knows (opaque id when sensitive).
fn log_network_task_refusal(
    msg: &ClientMsg,
    session_mgr: &Arc<Mutex<SessionManager>>,
    sensitive: &SensitiveTags,
) {
    use crate::model::activity::{activity_path, append_task, Outcome, TaskActivity, TaskActivityKind};
    let (kind, tag, what) = match msg {
        ClientMsg::SessionTaskStop { tag, .. } => (TaskActivityKind::TaskStop, tag, "Task stop"),
        ClientMsg::SessionTaskOutput { tag, .. } => (TaskActivityKind::TaskOutput, tag, "Task output read"),
        _ => return,
    };
    if !refusal_line_allowed() {
        return;
    }
    // A sensitive focus is named by nothing at all, not even its opaque id: the
    // line reaches network peers through the activity stream, and an id that
    // appeared only for sensitive tags would tell a guessing peer which of its
    // guesses are real (an unknown tag is logged unnamed too).
    let (tag, agent) = known_focus(&session_mgr.lock().unwrap(), tag);
    let (tag, agent) = match tag {
        Some(t) if !sensitive.tag_is_sensitive(&t) => (Some(t), agent),
        _ => (None, None),
    };
    let agent = agent.filter(|a| !a.is_empty()).unwrap_or_else(|| "claude".to_owned());
    append_task(
        &activity_path(),
        &TaskActivity {
            agent: agent.clone(),
            kind,
            summary: format!("{what} from a network client refused: requires a secure connection."),
            session_id: None,
            agent_type: Some(agent),
            focus_tag: tag,
            actor: "network".to_owned(),
            task_kind: None,
            description: None,
            outcome: Outcome::Refused,
            reason: Some("requires_secure_connection".to_owned()),
        },
    );
}

/// At most [`REFUSAL_LINES_PER_MINUTE`] network-refusal activity lines per
/// minute, daemon-wide.
fn refusal_line_allowed() -> bool {
    const REFUSAL_LINES_PER_MINUTE: u32 = 20;
    static WINDOW: Mutex<Option<(std::time::Instant, u32)>> = Mutex::new(None);
    let mut window = WINDOW.lock().unwrap_or_else(|e| e.into_inner());
    let now = std::time::Instant::now();
    match window.as_mut() {
        Some((start, count)) if now.duration_since(*start) < std::time::Duration::from_secs(60) => {
            *count += 1;
            *count <= REFUSAL_LINES_PER_MINUTE
        }
        _ => {
            *window = Some((now, 1));
            true
        }
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

/// Who a peer is, for the audit log: `{trust, pid?, exe?}`.
fn peer_json(trust: PeerTrust, peer: Option<&PeerInfo>) -> serde_json::Value {
    let mut v = serde_json::json!({
        "trust": match trust {
            PeerTrust::OperatorApp => "operator_app",
            PeerTrust::LocalOther => "local_other",
            PeerTrust::Tcp => "tcp",
        },
    });
    if let Some(p) = peer {
        v["pid"] = serde_json::json!(p.pid);
        v["exe"] = serde_json::json!(p.exe.display().to_string());
    }
    v
}

/// Refuse an `ApprovalAnswer`: log the refusal, then send `reply` (so the peer is
/// never told "refused" before the log says so).
fn refuse_approval_answer(
    broker: Option<ApprovalBroker>,
    targeted_tx: &mpsc::UnboundedSender<ServerMsg>,
    request_id: String,
    code: AnswerRefusal,
    reply: ServerMsg,
    peer: serde_json::Value,
) {
    let tx = targeted_tx.clone();
    audit_refusal_then(broker, Some(request_id), code.as_str(), peer, None, None, move || {
        let _ = tx.send(reply);
    });
}

/// Write a `refusal` audit entry on the blocking pool, then run `then` (the reply
/// to the peer), so the peer is never told "refused" before the log says so.
fn audit_refusal_then(
    broker: Option<ApprovalBroker>,
    request_id: Option<String>,
    code: &'static str,
    peer: serde_json::Value,
    channel: Option<RefusalChannel>,
    control: Option<String>,
    then: impl FnOnce() + Send + 'static,
) {
    tokio::task::spawn_blocking(move || {
        if let Some(broker) = broker {
            broker.record_refusal(request_id.as_deref(), code, peer, channel, control.as_deref());
        }
        then();
    });
}

/// Answer a refused request from a network peer with
/// `requires_secure_connection`, in the targeted frame that matches the
/// request (or a plain `Error` for requests that have no result frame).
fn refuse_over_network(msg: &ClientMsg, targeted_tx: &mpsc::UnboundedSender<ServerMsg>) {
    let _ = targeted_tx.send(network_refusal_reply(msg));
}

/// The frame `refuse_over_network` sends for `msg`.
fn network_refusal_reply(msg: &ClientMsg) -> ServerMsg {
    let refusal = WorkError::requires_secure_connection();
    match msg {
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
        ClientMsg::SessionModelSet { request_id, .. } | ClientMsg::ModelDefaultSet { request_id, .. } => {
            ServerMsg::ModelRequestResult {
                request_id: request_id.clone(),
                status: crate::ipc::protocol::ModelRequestStatus::Refused,
                code: Some(refusal.code.clone()),
                message: Some(refusal.message.clone()),
                warning: None,
            }
        }
        ClientMsg::SessionTaskStop { request_id, tag, task_id } => ServerMsg::SessionTaskStopResult {
            request_id: request_id.clone(),
            tag: tag.clone(),
            task_id: task_id.clone(),
            outcome: crate::ipc::protocol::TaskStopOutcome::Refused,
            message: Some(format!("{}: {}", refusal.code, refusal.message)),
        },
        ClientMsg::SessionTaskOutput { request_id, tag, task_id, .. } => ServerMsg::SessionTaskOutputResult {
            request_id: request_id.clone(),
            tag: tag.clone(),
            task_id: task_id.clone(),
            outcome: crate::ipc::protocol::TaskOutputOutcome::Refused,
            text: String::new(),
            start_offset: 0,
            end_offset: 0,
            total_bytes: 0,
            source: None,
            message: Some(format!("{}: {}", refusal.code, refusal.message)),
        },
        _ => ServerMsg::Error {
            message: format!("{}: {}", refusal.code, refusal.message),
        },
    }
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
/// state it can no longer vouch for, and asks every source to publish again so
/// the cache is repopulated: a Mac that reconnects after a lag must not wait
/// for a source to change on its own before it is replayed anything.
///
/// Two kinds of source: the work service (refreshed here) and the pollers that
/// own the retained `fred`/`teri` frames (poked through `republish`).
/// Lag-triggered refreshes are coalesced: at most one runs at a time, and a
/// burst of lags during it costs one more run, not one per lag.
async fn retain_broadcasts(
    mut rx: broadcast::Receiver<ServerMsg>,
    cache: RetainedCache,
    republish: tokio::sync::watch::Sender<u64>,
) {
    let resync = Arc::new(Mutex::new(Resync::Idle));
    loop {
        match rx.recv().await {
            Ok(msg) => apply_retention(&mut cache.lock().unwrap(), msg),
            Err(broadcast::error::RecvError::Lagged(n)) => {
                warn!("retained-message cache lagged {n} broadcast messages; clearing it and refreshing the sources");
                cache.lock().unwrap().clear();
                republish.send_modify(|generation| *generation = generation.wrapping_add(1));
                request_work_resync(&resync);
            }
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}

/// Keep the set of held Mother jobs current from the `MotherJobs` frames the daemon broadcasts.
/// A lagged receiver just carries on: the next frame (the poller sends one every two seconds)
/// replaces the set.
async fn track_held_mother_jobs(mut rx: broadcast::Receiver<ServerMsg>, held: HeldMotherJobs) {
    loop {
        match rx.recv().await {
            Ok(ServerMsg::MotherJobs { jobs }) => {
                let ids = jobs.iter().filter(|j| j.open_decision().is_some()).map(|j| j.id.clone()).collect();
                *held.lock().unwrap() = ids;
            }
            Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}

/// State of the lag-triggered work refresh.
#[derive(Debug, PartialEq, Eq)]
enum Resync {
    Idle,
    /// A refresh is in flight.
    Running,
    /// A refresh is in flight and another lag arrived meanwhile: run once more.
    RunAgain,
}

/// Refresh the work sources, unless a refresh is already in flight, in which
/// case ask it to run once more when it finishes.
fn request_work_resync(state: &Arc<Mutex<Resync>>) {
    {
        let mut st = state.lock().unwrap();
        match *st {
            Resync::Idle => *st = Resync::Running,
            Resync::Running | Resync::RunAgain => {
                *st = Resync::RunAgain;
                return;
            }
        }
    }
    let state = Arc::clone(state);
    tokio::spawn(async move {
        loop {
            let service = work_service();
            if let Err(e) = service.refresh(None, true).await {
                debug!(code = %e.code, "retention resync: refresh not performed");
            }
            if let Err(e) = service.refresh_picks("retention_lag").await {
                debug!(code = %e.code, "retention resync: picks refresh not performed");
            }
            let mut st = state.lock().unwrap();
            if *st == Resync::RunAgain {
                *st = Resync::Running;
                continue;
            }
            *st = Resync::Idle;
            break;
        }
    });
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

/// Does this broadcast go to a connection with these topics, which does or does
/// not present approvals (is the verified Mac app and subscribed with
/// `renders_approvals`)? The approval frames that carry a command go to
/// presenters and nobody else; the count also goes to a `decision` subscriber
/// and to an everything-subscriber. Network redaction still applies after this
/// (see [`outbound`]).
fn deliver_broadcast(msg: &ServerMsg, topics: &[Topic], presents_approvals: bool) -> bool {
    (presents_approvals && is_approval_frame(msg)) || message_matches_topics(msg, topics)
}

fn is_approval_frame(msg: &ServerMsg) -> bool {
    matches!(
        msg,
        ServerMsg::ApprovalRequest { .. }
            | ServerMsg::ApprovalsSnapshot { .. }
            | ServerMsg::ApprovalResolved { .. }
            | ServerMsg::ApprovalGuardBlocked { .. }
            | ServerMsg::ApprovalAnswerRefused { .. }
            | ServerMsg::ApprovalPending { .. }
    )
}

fn message_matches_topics(msg: &ServerMsg, topics: &[Topic]) -> bool {
    match msg {
        // Presenters only (see `deliver_broadcast`): never by topic.
        ServerMsg::ApprovalRequest { .. }
        | ServerMsg::ApprovalsSnapshot { .. }
        | ServerMsg::ApprovalResolved { .. }
        | ServerMsg::ApprovalGuardBlocked { .. }
        | ServerMsg::ApprovalAnswerRefused { .. }
        | ServerMsg::SessionPermissionRequest { .. } => false,
        // The count: for anyone who follows decisions (an empty list included).
        ServerMsg::ApprovalPending { .. } => subscribed(topics, Topic::Decision),
        // Which sessions wait for a Claude sign-in: every local subscriber, whatever
        // its topics (like `Error`). A network peer never gets it (`LocalOnly`).
        ServerMsg::ClaudeLoginState { .. } => true,
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
        ServerMsg::ModelCatalog { .. }
        | ServerMsg::ModelDefaults { .. }
        | ServerMsg::SessionModelState(_) => wants_model(topics),
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
    #[test]
    fn welcome_reports_only_the_enabled_agents() {
        let mut mgr = SessionManager::new();
        match welcome_msg(&mgr, None) {
            ServerMsg::Welcome { enabled_agents, disabled_agents, .. } => {
                assert_eq!(enabled_agents, Some(vec!["fred".into(), "mother".into(), "perri".into(), "teri".into()]));
                assert_eq!(disabled_agents, Some(vec![]), "nothing is off");
            }
            other => panic!("{other:?}"),
        }
        mgr.configure_enabled_agents(crate::agents::EnabledAgents { fred: false, perri: true, teri: true });
        match welcome_msg(&mgr, None) {
            ServerMsg::Welcome { enabled_agents, disabled_agents, .. } => {
                assert_eq!(enabled_agents, Some(vec!["mother".into(), "perri".into(), "teri".into()]));
                assert_eq!(disabled_agents, Some(vec!["fred".to_string()]));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_refusal_reason_is_short_and_free_of_control_characters() {
        let long = format!("nope\n\x1b[31m{}", "x".repeat(500));
        let reason = bounded_reason(&long);
        assert!(reason.chars().count() <= 120, "{}", reason.chars().count());
        assert!(!reason.chars().any(|c| c.is_control()), "{reason:?}");
        assert!(reason.starts_with("nope"));
    }

    use super::*;
    use crate::ipc::protocol::DecisionChoice;

    fn perri_action_with(enabled: crate::agents::EnabledAgents, dir: &Path) -> Vec<ServerMsg> {
        let mut mgr = SessionManager::new();
        mgr.configure_enabled_agents(enabled);
        let mgr = Arc::new(Mutex::new(mgr));
        let (ttx, mut trx) = mpsc::unbounded_channel();
        let (btx, _brx) = broadcast::channel(8);
        handle_client_msg(
            ClientMsg::PerriAction { action: "load_pr".into(), pr_number: Some(7), repo: Some("o/r".into()), tag: None },
            PeerTrust::OperatorApp,
            None,
            None,
            &SensitiveTags::in_memory(),
            "conn",
            "client",
            &mgr,
            &ttx,
            &btx,
            dir,
            &Arc::new(Mutex::new(DecisionRegistry::new())),
            &Arc::new(Mutex::new(HashSet::new())),
        );
        let mut out = Vec::new();
        while let Ok(m) = trx.try_recv() {
            out.push(m);
        }
        out
    }

    #[test]
    fn perri_action_is_refused_without_touching_state_when_perri_is_disabled() {
        let dir = tempfile::tempdir().unwrap();
        let off = crate::agents::EnabledAgents { fred: true, perri: false, teri: true };
        let out = perri_action_with(off, dir.path());
        assert!(
            matches!(out.as_slice(), [ServerMsg::Error { message }] if message == PERRI_DISABLED),
            "{out:?}"
        );
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0, "no Perri state files written");
    }

    #[tokio::test]
    async fn perri_action_still_runs_when_perri_is_enabled() {
        let dir = tempfile::tempdir().unwrap();
        let out = perri_action_with(crate::agents::EnabledAgents::all(), dir.path());
        assert!(out.is_empty(), "{out:?}");
        // The action runs on a spawned task; wait for its state file.
        for _ in 0..100 {
            if std::fs::read_dir(dir.path()).unwrap().count() > 0 {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        panic!("enabled Perri's load_pr wrote nothing");
    }

    #[test]
    fn log_safe_strips_newlines_and_bounds_length() {
        let nasty = format!("a\nb\r\nINFO forged line\u{202e}{}", "x".repeat(4 * 1024 * 1024));
        let out = log_safe(&nasty);
        assert!(!out.contains('\n') && !out.contains('\r') && !out.contains('\u{202e}'), "{out:?}");
        assert!(out.len() <= 256, "{}", out.len());
        assert_eq!(log_safe("req-1"), "req-1");
    }

    #[test]
    fn frame_type_names_the_variant_and_never_the_content() {
        let bytes = br#"{"type":"approval_answer","request_id":"SECRET-CONTENT"}"#;
        assert_eq!(frame_type(bytes), "approval_answer");
        assert_eq!(frame_type(b"not json SECRET"), "unreadable");
        assert_eq!(frame_type(b"{\"type\":\"a\\nb\"}"), "a b");
    }

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
                    is_default: false,
                },
                DecisionChoice {
                    id: "reject".into(),
                    label: "Reject".into(),
                    detail: None,
                    is_default: false,
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

    // ── model topic: only clients that name it get model frames and notes ──

    fn note_block() -> crate::ipc::stream_json::TurnBlock {
        crate::ipc::stream_json::TurnBlock::Note {
            note_kind: crate::model::notes::NoteKind::ModelChanged,
            text: "Model changed to Opus (from Sonnet) by you.".into(),
            ts: chrono::Utc::now(),
        }
    }

    fn turn_with_note() -> crate::ipc::stream_json::Turn {
        crate::ipc::stream_json::Turn {
            id: "t0".into(),
            user_input: "hi".into(),
            timestamp: None,
            blocks: vec![note_block(), crate::ipc::stream_json::TurnBlock::text("hello")],
            is_complete: true,
        }
    }

    #[test]
    fn model_frames_go_only_to_clients_that_name_the_model_topic() {
        let catalog = ServerMsg::ModelCatalog { families: vec![], stale: false, fetched_at: None };
        assert!(message_matches_topics(&catalog, &[Topic::Model]));
        assert!(!message_matches_topics(&catalog, &[]), "the everything-list predates model frames");
        assert!(!message_matches_topics(&catalog, &[Topic::Activity]));
    }

    #[test]
    fn a_client_that_has_not_asked_for_model_frames_gets_transcripts_without_notes() {
        let turns = ServerMsg::SessionTurns { tag: "cody-1".into(), turns: vec![turn_with_note()] };
        match without_notes_unless_model(turns.clone(), &[Topic::Activity]) {
            Some(ServerMsg::SessionTurns { turns, .. }) => {
                assert_eq!(turns[0].blocks, vec![crate::ipc::stream_json::TurnBlock::text("hello")]);
            }
            other => panic!("{other:?}"),
        }
        let note = ServerMsg::SessionTurnDelta {
            tag: "cody-1".into(),
            delta: crate::ipc::stream_json::TurnDelta::Note { turn_id: Some("t0".into()), block: note_block() },
        };
        assert!(without_notes_unless_model(note.clone(), &[]).is_none());
        // A client that names the topic gets both untouched.
        assert!(without_notes_unless_model(note, &[Topic::Model]).is_some());
        match without_notes_unless_model(turns, &[Topic::Model]) {
            Some(ServerMsg::SessionTurns { turns, .. }) => assert_eq!(turns[0].blocks.len(), 2),
            other => panic!("{other:?}"),
        }
    }

    // ── background tasks ────────────────────────────────────────────────────

    fn tasks_frame() -> ServerMsg {
        ServerMsg::SessionTasks {
            tag: "cody-1".into(),
            session_id: Some("sess".into()),
            daemon_epoch: "epoch".into(),
            stop_supported: None,
            tasks: vec![],
        }
    }

    fn task_detail_frame() -> ServerMsg {
        ServerMsg::SessionTaskDetail {
            tag: "cody-1".into(),
            task_id: "t1".into(),
            preview: Some("line".into()),
            progress_summary: None,
            completion_summary: None,
            prompt: None,
        }
    }

    #[test]
    fn the_task_frames_reach_a_client_whatever_topics_it_named() {
        // Like the other session frames, they are not behind a topic: a client
        // attached to the session gets them, and an old client ignores the type.
        for topics in [
            vec![],
            vec![Topic::Activity],
            vec![Topic::Model],
            vec![Topic::Work, Topic::Fred],
            vec![Topic::Layout, Topic::Focuses],
        ] {
            assert!(message_matches_topics(&tasks_frame(), &topics), "{topics:?}");
            assert!(message_matches_topics(&task_detail_frame(), &topics), "{topics:?}");
        }
    }

    #[test]
    fn the_tasks_capability_is_advertised_under_its_documented_name() {
        // `Welcome.features` carries this string; the Swift clients look for it.
        assert_eq!(FEATURE_TASKS, "tasks");
    }
}
