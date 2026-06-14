//! Daemon-side persistent stream-json session manager.
//!
//! `SessionManager` is to stream-json sessions what [`super::pty_manager::PtyManager`]
//! is to PTYs: it owns long-lived `claude` child processes on behalf of
//! `nostromd` so a session survives the GUI disconnecting, crashing, or
//! restarting. It is the daemon-side home of the persistent
//! `--input-format stream-json --output-format stream-json` session host.
//!
//! ## One process per focus
//!
//! Each focus `tag` is backed by **one** long-lived child:
//!
//! ```text
//! claude --dangerously-skip-permissions \
//!        --input-format stream-json --output-format stream-json --verbose \
//!        --replay-user-messages --agent <agent> -n <view> \
//!        [--remote-control <view>] (--session-id <uuid> | --resume <uuid>)
//! ```
//!
//! `--replay-user-messages` is always passed so every stdin-origin user message
//! is re-emitted on stdout tagged `"isReplay": true`. The daemon therefore
//! renders **all** user messages off the output stream (the unified input
//! model) — `send_user_message` only injects to stdin and never separately
//! broadcasts the local message; it comes back on the output stream like any
//! other turn. (Spike-confirmed against `claude` 2.1.158.)
//!
//! ## Output fan-out
//!
//! A blocking reader thread parses the child's stdout line-by-line into the
//! shared [`SessionTranscript`] and broadcasts [`SessionEvent`]s. A per-attached
//! client forwarder converts events into `ServerMsg::SessionTurnDelta` /
//! `SessionState` / `SessionExited` and writes them to the client's
//! per-connection sender — exactly mirroring `PtyManager`'s pattern, except
//! **multiple** clients may attach to one tag (mirroring is a broadcast).

use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use tokio::sync::{broadcast, mpsc};
use tracing::{debug, info, warn};
use uuid::Uuid;

use serde::{Deserialize, Serialize};

use super::pane_registry::PaneRegistry;
use super::protocol::{FocusMeta, ServerMsg, SessionInfo};
use super::stream_json::{load_scrollback, SessionState, SessionTranscript, Turn, TurnDelta};

/// Env var overriding the resolved `claude` binary path (used by tests and by
/// operators with a non-standard install).
pub const CLAUDE_BIN_ENV: &str = "NOSTROMO_CLAUDE_BIN";

/// How many scrollback turns to replay when resuming a session.
const SCROLLBACK_TURNS: usize = 30;

/// Crash-loop guard: at most this many auto-restarts within the sliding window.
const MAX_RESTARTS: u32 = 3;
/// Sliding-window span. A crash older than this falls off the back of the
/// crash-timestamp deque and no longer counts toward the guard.
const RESTART_WINDOW_SECS: u64 = 30;
/// Exponential-backoff base: wait `BACKOFF_BASE_SECS * 2^(n-1)` before the nth
/// transient restart (n = number of crashes already recorded this window).
const BACKOFF_BASE_SECS: u64 = 1;
/// Cap on a single backoff delay so a high crash count can't schedule an
/// absurd wait.
const BACKOFF_MAX_SECS: u64 = 60;

// ── stop reason ──────────────────────────────────────────────────────────────

/// Why a session was intentionally stopped (`alive == false`, but not a crash
/// the supervisor should recover from). Lets the GUI distinguish a benign
/// user-requested stop from an alarm-worthy crash-loop-guard trip.
///
/// `StaleId` is defined for wire completeness and future use; the daemon does
/// **not** set it today — the stale-id path clears the id and auto-respawns
/// fresh, so the session is never left intentionally stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    User,
    CrashLoopGuard,
    StaleId,
}

// ── broadcast event ─────────────────────────────────────────────────────────

/// Output unit broadcast by a session's reader thread.
#[derive(Debug, Clone)]
pub enum SessionEvent {
    Delta(TurnDelta),
    State(SessionState),
    Exited {
        exit_code: Option<i32>,
    },
    /// The session has been permanently stopped and will not auto-restart.
    /// Complements `Exited` (which fires on every exit) — this fires only when
    /// the supervisor has decided it is done trying. Clients should show a
    /// health indicator and offer recovery actions.
    PermanentlyDown {
        reason: StopReason,
    },
}

// ── pending-message queue ─────────────────────────────────────────────────────

/// A user message waiting in the pending queue, preserving image paths so they
/// survive the queued-until-idle path without being dropped.
#[derive(Clone)]
struct PendingMessage {
    text: String,
    /// Absolute file paths; daemon reads + base64-encodes at drain time.
    images: Vec<String>,
}

// ── shared, reader-thread-visible session state ───────────────────────────────

/// State shared between the manager (under its Mutex) and the detached reader
/// thread. Cloneable `Arc` handles only — no back-reference to the manager.
struct Shared {
    transcript: Arc<Mutex<SessionTranscript>>,
    /// Child stdin for writing user-message frames (manager + reader drain).
    stdin: Arc<Mutex<Option<ChildStdin>>>,
    /// Queued user messages awaiting an idle turn.
    pending: Arc<Mutex<VecDeque<PendingMessage>>>,
    /// Single source of truth for the live turn state.
    state: Arc<Mutex<SessionState>>,
    /// Set by the reader on stdout EOF (child exited / stream closed).
    exited: Arc<AtomicBool>,
    event_tx: broadcast::Sender<SessionEvent>,
}

impl Shared {
    fn broadcast(&self, ev: SessionEvent) {
        let _ = self.event_tx.send(ev);
    }

    fn set_state(&self, s: SessionState) {
        *self.state.lock().unwrap() = s;
        self.broadcast(SessionEvent::State(s));
    }
}

// ── managed session ───────────────────────────────────────────────────────────

struct ManagedSession {
    tag: String,
    agent_name: String,
    view_name: String,
    cwd: Option<PathBuf>,
    remote_control: bool,
    /// Resolved `claude` session id (persisted in the id store).
    session_id: Option<String>,
    child: Child,
    shared: Shared,
    /// How to respawn on restart. `None` → a real `claude` session (rebuild
    /// args with `--resume`). `Some((program, args))` → replay this exact
    /// program/args verbatim (used by tests to inject a stub child so restart
    /// never touches the real `claude` binary or the network).
    respawn_fixed: Option<(PathBuf, Vec<String>)>,
    /// Set true immediately before an intentional kill so the supervisor does
    /// not treat the resulting EOF as a crash to recover from.
    intentional_stop: Arc<AtomicBool>,
    /// Set by the stderr drain when the child emits "No conversation found",
    /// signalling a stale persisted session id. `reap_and_recover` checks this
    /// before the crash-loop guard and spawns fresh rather than retrying --resume.
    stale_session_id: Arc<AtomicBool>,
    attached_clients: HashSet<String>,
    /// Per-client forwarder abort handles.
    forwarders: HashMap<String, tokio::task::AbortHandle>,
    _reader_task: tokio::task::JoinHandle<()>,
    /// Sliding window of recent crash timestamps. On each detected crash we
    /// push `Instant::now()`, then evict entries older than RESTART_WINDOW_SECS
    /// from the front. `crash_times.len()` is the live crash count; when it
    /// reaches MAX_RESTARTS the crash-loop guard trips. Replaces the old
    /// fixed-window `restart_count` + `restart_window_start`.
    crash_times: VecDeque<Instant>,
    /// When set, `reap_and_recover` must not restart this session until
    /// `Instant::now() >= restart_at` — the exponential-backoff deadline for a
    /// transient (non-zero-exit) crash. `None` means "no pending backoff".
    restart_at: Option<Instant>,
    /// Last observed child exit code, captured via `child.try_wait()` in
    /// `reap_and_recover`. `None` = not yet reaped, killed by signal, or clean
    /// unknown. Surfaced through `SessionEvent::Exited { exit_code }`.
    last_exit_code: Option<i32>,
    /// Why this session is intentionally stopped, if it is. Set by `stop()`
    /// (User), the crash-loop guard in `reap_and_recover` (CrashLoopGuard), or
    /// `kill_all_on_shutdown` (left None — daemon teardown). Cleared (reset to
    /// None) whenever a new `ManagedSession` is spawned by `restart()`.
    pub(crate) stop_reason: Option<StopReason>,
    /// Guards the one-shot `SessionSummaryUpdate` emission per session lifetime.
    /// Set to `true` once the summary has been derived and broadcast to all
    /// connected clients. Resets on restart (new `ManagedSession`).
    summary_sent: Arc<AtomicBool>,
}

impl ManagedSession {
    fn alive(&self) -> bool {
        !self.shared.exited.load(Ordering::SeqCst)
    }

    fn state(&self) -> SessionState {
        *self.shared.state.lock().unwrap()
    }

    fn info(&self) -> SessionInfo {
        SessionInfo {
            tag: self.tag.clone(),
            agent_name: self.agent_name.clone(),
            view_name: self.view_name.clone(),
            session_id: self.session_id.clone(),
            alive: self.alive(),
            remote_control: self.remote_control,
            state: self.state(),
            stop_reason: self.stop_reason,
        }
    }
}

// ── SessionManager ────────────────────────────────────────────────────────────

/// Shared daemon-side registry of running stream-json sessions.
///
/// All public methods take `&mut self` — callers hold the wrapping Mutex.
pub struct SessionManager {
    sessions: HashMap<String, ManagedSession>,
    client_senders: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<ServerMsg>>>>,
    /// Path to the daemon-owned `tag -> session_id` store.
    store_path: PathBuf,
    /// Mac-pushed focus registry; served to all clients and broadcast on change.
    focus_registry: Vec<FocusMeta>,
    /// Per-focus pane-tree registry. Set by the daemon via
    /// [`SessionManager::configure_mcp_bridge`]; `None` in tests / non-daemon use.
    /// A fresh (non-resume) spawn initialises the focus's tree to a single REPL
    /// leaf so the agent's first turn assembles from a known baseline.
    pane_registry: Option<Arc<Mutex<PaneRegistry>>>,
    /// Daemon MCP socket path injected as `NOSTROMO_MCP_SOCKET` into sessions.
    mcp_socket: Option<PathBuf>,
    /// `--mcp-config` file path registering the `nostromo-mcp-bridge` stdio server.
    mcp_config: Option<PathBuf>,
}

impl SessionManager {
    pub fn new() -> Self {
        Self::with_store_path(default_store_path())
    }

    pub fn with_store_path(store_path: PathBuf) -> Self {
        Self {
            sessions: HashMap::new(),
            client_senders: Arc::new(Mutex::new(HashMap::new())),
            store_path,
            focus_registry: Vec::new(),
            pane_registry: None,
            mcp_socket: None,
            mcp_config: None,
        }
    }

    /// Wire the daemon-hosted MCP bridge: the shared pane registry plus the
    /// socket + config paths injected into every freshly spawned session so the
    /// child `claude` can reach the layout/introspection tool surface.
    pub fn configure_mcp_bridge(
        &mut self,
        pane_registry: Arc<Mutex<PaneRegistry>>,
        mcp_socket: PathBuf,
        mcp_config: PathBuf,
    ) {
        self.pane_registry = Some(pane_registry);
        self.mcp_socket = Some(mcp_socket);
        self.mcp_config = Some(mcp_config);
    }

    /// Access the shared pane registry (if wired up). Used by the IPC server
    /// to replay layout state to newly connected clients without threading
    /// the Arc through every accept-loop call site.
    pub fn pane_registry(&self) -> Option<Arc<Mutex<PaneRegistry>>> {
        self.pane_registry.clone()
    }

    pub fn client_sender_registry(
        &self,
    ) -> Arc<Mutex<HashMap<String, mpsc::UnboundedSender<ServerMsg>>>> {
        Arc::clone(&self.client_senders)
    }

    // ── spawn ───────────────────────────────────────────────────────────────

    /// Spawn (or resume) a focus's persistent session. Idempotent: if the tag
    /// already has a live child this is a no-op returning the known session id.
    pub fn spawn_session(
        &mut self,
        tag: String,
        agent_name: String,
        view_name: String,
        cwd: Option<PathBuf>,
        session_id: Option<String>,
        remote_control: bool,
    ) -> Result<Option<String>> {
        if let Some(existing) = self.sessions.get(&tag) {
            if existing.alive() {
                return Ok(existing.session_id.clone());
            }
        }

        // Resolve the session id: explicit arg › persisted store › fresh uuid.
        let store = load_id_store(&self.store_path);
        let resolved = session_id.or_else(|| store.get(&tag).cloned());
        let (effective_id, resume) = match resolved {
            Some(id) => (id, true),
            None => (Uuid::new_v4().to_string(), false),
        };

        let program = resolve_claude()?;
        let args = build_claude_args(
            &agent_name,
            &view_name,
            remote_control,
            &effective_id,
            resume,
        );

        let managed = self.spawn_managed(
            tag.clone(),
            agent_name,
            view_name,
            cwd,
            remote_control,
            effective_id.clone(),
            resume,
            program,
            args,
            None,
        )?;

        self.sessions.insert(tag.clone(), managed);

        // A fresh (non-resume) spawn starts from a known baseline: a single REPL
        // pane the agent grows on its first turn. A resume keeps the persisted
        // tree (loaded from the pane store) so a reconnecting client sees the
        // already-assembled workspace.
        if !resume {
            if let Some(reg) = &self.pane_registry {
                reg.lock().unwrap().init_focus(&tag);
            }
        }

        // Persist the (possibly freshly generated) id for the tag.
        save_id(&self.store_path, &tag, Some(&effective_id));
        info!(tag, session_id = %effective_id, resume, "session spawned");
        Ok(Some(effective_id))
    }

    /// Spawn an arbitrary program as a session child. Factored out so tests can
    /// inject a stub program in place of `claude`.
    #[allow(clippy::too_many_arguments)]
    fn spawn_managed(
        &self,
        tag: String,
        agent_name: String,
        view_name: String,
        cwd: Option<PathBuf>,
        remote_control: bool,
        session_id: String,
        resume: bool,
        program: PathBuf,
        args: Vec<String>,
        respawn_fixed: Option<(PathBuf, Vec<String>)>,
    ) -> Result<ManagedSession> {
        // Pre-populate the transcript from stored scrollback when resuming.
        let transcript = if resume {
            load_scrollback(&session_id, SCROLLBACK_TURNS)
        } else {
            SessionTranscript::new()
        };

        let mut cmd = Command::new(&program);
        cmd.args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()); // piped for crash diagnostics (was null)

        // MCP bridge wiring for real (non-stubbed) `claude` sessions. The child
        // registers the `nostromo-mcp-bridge` stdio server (--mcp-config) and
        // inherits the identity env the bridge forwards in its Hello frame, so
        // the agent can call the layout/introspection tools against the daemon.
        // The focus tag is the identity key (NOSTROMO_PTY_ID) and the view id.
        if respawn_fixed.is_none() {
            if let (Some(socket), Some(config)) = (&self.mcp_socket, &self.mcp_config) {
                cmd.env("NOSTROMO_MCP_SOCKET", socket);
                cmd.env("NOSTROMO_PTY_ID", &tag);
                cmd.env("NOSTROMO_VIEW_ID", &tag);
                cmd.arg("--mcp-config").arg(config);
            }
        }
                                     // Child working directory. When the focus carries no project dir, default
                                     // to the operator's $HOME — NOT the daemon's own cwd, which under launchd
                                     // is `/` (filesystem root). Running an agent at `/` has no git context, so
                                     // `gh` can't infer owner/repo and repo-aware commands (Perri's, etc.) fail
                                     // in ways they never do when launched from a real dir. $HOME matches what a
                                     // terminal-launched agent would typically see.
        let dir = cwd
            .clone()
            .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
            .or_else(|| std::env::current_dir().ok());
        if let Some(dir) = dir {
            cmd.current_dir(dir);
        }
        augment_path(&mut cmd);

        let mut child = cmd
            .spawn()
            .map_err(|e| anyhow!("failed to spawn {}: {e}", program.display()))?;

        let stdin = child.stdin.take();
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("child has no stdout"))?;
        let stderr = child.stderr.take();

        let (event_tx, _) = broadcast::channel::<SessionEvent>(512);
        let shared = Shared {
            transcript: Arc::new(Mutex::new(transcript)),
            stdin: Arc::new(Mutex::new(stdin)),
            pending: Arc::new(Mutex::new(VecDeque::new())),
            state: Arc::new(Mutex::new(SessionState::Idle)),
            exited: Arc::new(AtomicBool::new(false)),
            event_tx,
        };

        // Stderr drain thread: read and log stderr lines so crash output is
        // visible in the nostromd log rather than silently discarded.
        // Also detects the "No conversation found" permanent error and sets
        // `stale_session_id` so `reap_and_recover` can clear the id and
        // restart fresh rather than looping on the same stale id.
        let stale_session_id = Arc::new(AtomicBool::new(false));
        let stale_for_stderr = Arc::clone(&stale_session_id);
        let tag_for_stderr = tag.clone();
        if let Some(stderr_pipe) = stderr {
            tokio::task::spawn_blocking(move || {
                use std::io::BufRead as _;
                let reader = std::io::BufReader::new(stderr_pipe);
                for line in reader.lines().map_while(Result::ok) {
                    let line = line.trim().to_owned();
                    if line.is_empty() {
                        continue;
                    }
                    if line.contains("No conversation found") {
                        stale_for_stderr.store(true, Ordering::SeqCst);
                        warn!(tag = %tag_for_stderr, "stale session id detected — will clear and restart fresh");
                    } else {
                        warn!(tag = %tag_for_stderr, "[stderr] {line}");
                    }
                }
            });
        }

        // Reader thread: parse stdout → transcript → broadcast deltas; drain
        // the pending queue on turn completion; signal exit on EOF.
        let reader_shared = Shared {
            transcript: Arc::clone(&shared.transcript),
            stdin: Arc::clone(&shared.stdin),
            pending: Arc::clone(&shared.pending),
            state: Arc::clone(&shared.state),
            exited: Arc::clone(&shared.exited),
            event_tx: shared.event_tx.clone(),
        };
        let tag_for_reader = tag.clone();
        let reader_task =
            tokio::task::spawn_blocking(move || run_reader(tag_for_reader, stdout, reader_shared));

        Ok(ManagedSession {
            tag,
            agent_name,
            view_name,
            cwd,
            remote_control,
            session_id: Some(session_id),
            child,
            shared,
            respawn_fixed,
            intentional_stop: Arc::new(AtomicBool::new(false)),
            stale_session_id,
            attached_clients: HashSet::new(),
            forwarders: HashMap::new(),
            _reader_task: reader_task,
            crash_times: VecDeque::new(),
            restart_at: None,
            last_exit_code: None,
            stop_reason: None,
            summary_sent: Arc::new(AtomicBool::new(false)),
        })
    }

    // ── send ──────────────────────────────────────────────────────────────────

    /// Enqueue a user message. Writes immediately to stdin if the session is
    /// idle, otherwise queues it to drain after the current turn completes.
    pub fn send_user_message(
        &mut self,
        tag: &str,
        text: &str,
        images: &[String],
    ) -> Result<()> {
        let session = self
            .sessions
            .get(tag)
            .ok_or_else(|| anyhow!("unknown session tag: {tag}"))?;
        if !session.alive() {
            anyhow::bail!("session {tag} is not alive");
        }

        // Decide under the state lock, then release it BEFORE touching stdin.
        // The reader's drain path locks stdin then state; if we held state while
        // acquiring stdin we'd risk an AB-BA deadlock. Acquiring each lock in a
        // separate, non-overlapping critical section avoids that entirely.
        let should_write = {
            let mut state = session.shared.state.lock().unwrap();
            if *state == SessionState::Idle {
                // Optimistically mark mid-turn so a follow-up send queues rather
                // than racing a second message onto stdin before the echo lands.
                *state = SessionState::MidTurn;
                true
            } else {
                false
            }
        };

        if should_write {
            if let Err(e) = write_user_frame(&session.shared.stdin, text, images) {
                // The optimistic MidTurn would otherwise wedge the session.
                *session.shared.state.lock().unwrap() = SessionState::Idle;
                return Err(e);
            }
            session
                .shared
                .broadcast(SessionEvent::State(SessionState::MidTurn));
        } else {
            session
                .shared
                .pending
                .lock()
                .unwrap()
                .push_back(PendingMessage {
                    text: text.to_string(),
                    images: images.to_vec(),
                });
        }
        Ok(())
    }

    // ── attach / detach ─────────────────────────────────────────────────────

    /// Attach `client_id` to `tag`: send a `SessionTurns` snapshot + current
    /// `SessionState`, then forward live events. Multiple clients may attach.
    pub fn attach(&mut self, tag: &str, client_id: &str) -> Result<()> {
        let (turns, state, event_rx) = {
            let session = self
                .sessions
                .get_mut(tag)
                .ok_or_else(|| anyhow!("unknown session tag: {tag}"))?;
            session.attached_clients.insert(client_id.to_string());
            let turns = session.shared.transcript.lock().unwrap().snapshot();
            let state = session.state();
            let rx = session.shared.event_tx.subscribe();
            (turns, state, rx)
        };

        self.send_to_client(
            client_id,
            ServerMsg::SessionTurns {
                tag: tag.to_string(),
                turns,
            },
        );
        self.send_to_client(
            client_id,
            ServerMsg::SessionState {
                tag: tag.to_string(),
                state,
            },
        );

        // Forwarder task: SessionEvent → targeted ServerMsg.
        let senders = Arc::clone(&self.client_senders);
        let tag_s = tag.to_string();
        let client_s = client_id.to_string();
        let mut rx = event_rx;
        let task = tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(ev) => {
                        let msg = match ev {
                            SessionEvent::Delta(delta) => ServerMsg::SessionTurnDelta {
                                tag: tag_s.clone(),
                                delta,
                            },
                            SessionEvent::State(state) => ServerMsg::SessionState {
                                tag: tag_s.clone(),
                                state,
                            },
                            SessionEvent::Exited { exit_code } => ServerMsg::SessionExited {
                                tag: tag_s.clone(),
                                exit_code,
                            },
                            SessionEvent::PermanentlyDown { reason } => ServerMsg::SessionDown {
                                tag: tag_s.clone(),
                                reason,
                            },
                        };
                        let guard = senders.lock().unwrap();
                        match guard.get(&client_s) {
                            Some(tx) => {
                                let _ = tx.send(msg);
                            }
                            None => break, // client disconnected
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!(tag = %tag_s, client = %client_s, "session forwarder lagged {n}");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });

        if let Some(session) = self.sessions.get_mut(tag) {
            session
                .forwarders
                .insert(client_id.to_string(), task.abort_handle());
        }
        info!(tag, client_id, "session attach");
        Ok(())
    }

    /// Detach `client_id` from `tag` (the child keeps running).
    pub fn detach(&mut self, tag: &str, client_id: &str) {
        if let Some(session) = self.sessions.get_mut(tag) {
            session.attached_clients.remove(client_id);
            if let Some(h) = session.forwarders.remove(client_id) {
                h.abort();
            }
        }
    }

    // ── lifecycle control ─────────────────────────────────────────────────────

    /// Stop the child but keep the persisted session id (resumable).
    ///
    /// Sets `stop_reason = User` and broadcasts `PermanentlyDown { reason: User }`
    /// so attached clients can clear any crash-loop indicator (this was a benign
    /// user-requested stop, not an alarm).
    pub fn stop(&mut self, tag: &str) {
        if let Some(session) = self.sessions.get_mut(tag) {
            session.intentional_stop.store(true, Ordering::SeqCst);
            session.stop_reason = Some(StopReason::User);
            let _ = session.child.kill();
            session.shared.exited.store(true, Ordering::SeqCst);
            session.shared.broadcast(SessionEvent::PermanentlyDown {
                reason: StopReason::User,
            });
            for (_, h) in session.forwarders.drain() {
                h.abort();
            }
            debug!(tag, "session stopped");
        }
    }

    /// Stop then respawn with `--resume <session_id>`, preserving the set of
    /// attached clients (mirroring survives a restart).
    ///
    /// Explicitly resets the crash-loop guard: the new `ManagedSession` is built
    /// by `spawn_managed` which starts with `crash_times = VecDeque::new()`,
    /// `restart_at = None`, and `stop_reason = None` — so a user-initiated
    /// Restart of a guard-tripped session always retries cleanly from a fresh
    /// slate. This intent is preserved whether the crash-loop guard uses the
    /// current fixed-window fields or future sliding-window fields.
    pub fn restart(&mut self, tag: &str) -> Result<()> {
        let (agent, view, cwd, sid, rc, fixed, attached) = {
            let s = self
                .sessions
                .get(tag)
                .ok_or_else(|| anyhow!("unknown session tag: {tag}"))?;
            (
                s.agent_name.clone(),
                s.view_name.clone(),
                s.cwd.clone(),
                s.session_id.clone(),
                s.remote_control,
                s.respawn_fixed.clone(),
                s.attached_clients.iter().cloned().collect::<Vec<_>>(),
            )
        };
        self.stop(tag);
        self.sessions.remove(tag);

        match fixed {
            // Real claude session: resolve the binary and resume.
            None => {
                self.spawn_session(tag.to_string(), agent, view, cwd, sid, rc)?;
            }
            // Test stub / fixed program: replay it verbatim.
            Some((program, args)) => {
                let effective_id = sid.unwrap_or_else(|| Uuid::new_v4().to_string());
                let managed = self.spawn_managed(
                    tag.to_string(),
                    agent,
                    view,
                    cwd,
                    rc,
                    effective_id,
                    true,
                    program.clone(),
                    args.clone(),
                    Some((program, args)),
                )?;
                self.sessions.insert(tag.to_string(), managed);
            }
        }

        // Re-attach previously attached clients so the GUI re-syncs after a
        // transparent restart.
        for client_id in attached {
            let _ = self.attach(tag, &client_id);
        }
        Ok(())
    }

    /// Drop the persisted session id and stop the child; the next spawn starts
    /// a fresh conversation.
    pub fn new_session(&mut self, tag: &str) {
        self.stop(tag);
        self.sessions.remove(tag);
        save_id(&self.store_path, tag, None);
        debug!(tag, "session id cleared — next spawn is fresh");
    }

    /// Periodic supervisor pass (driven by the daemon): detect crashed children
    /// and auto-restart those still wanted (attached or with queued messages),
    /// subject to the crash-loop guard.
    ///
    /// Each crashed session goes through three phases per tick:
    ///
    /// 1. **Backoff check**: if we already scheduled a backoff deadline for this
    ///    crash, skip this tick (still waiting) or clear it (deadline elapsed).
    /// 2. **First-sighting bookkeeping** (only on the initial crash detection,
    ///    not repeated while backing off): capture the exit code, re-broadcast
    ///    `Exited` with the real code, mark the turn errored, record the crash
    ///    in the sliding window.
    /// 3. **Decision**: guard check, then exit-code-aware restart or backoff
    ///    scheduling.
    pub fn reap_and_recover(&mut self) {
        let crashed: Vec<String> = self
            .sessions
            .iter()
            .filter(|(_, s)| {
                s.shared.exited.load(Ordering::SeqCst) && !s.intentional_stop.load(Ordering::SeqCst)
            })
            .map(|(tag, _)| tag.clone())
            .collect();

        for tag in crashed {
            // ── phase 1: backoff check ────────────────────────────────────────
            //
            // A session can sit crashed across multiple 2s supervisor ticks
            // while its backoff deadline counts down. Use restart_at as the
            // "already-bookekept, waiting" sentinel: Some(future) → skip;
            // Some(past) → deadline elapsed, clear it and proceed to restart;
            // None → first sighting, run bookkeeping.
            let backoff_served;
            {
                let s = self.sessions.get_mut(&tag).unwrap();
                match s.restart_at {
                    Some(deadline) if Instant::now() < deadline => {
                        continue; // still backing off; do nothing this tick
                    }
                    Some(_) => {
                        // Deadline reached — clear and fall through to restart.
                        // Bookkeeping was already done when we scheduled this.
                        s.restart_at = None;
                        backoff_served = true;
                    }
                    None => {
                        backoff_served = false;
                    }
                }
            }

            // ── phase 2: first-sighting bookkeeping ───────────────────────────
            if !backoff_served {
                let s = self.sessions.get_mut(&tag).unwrap();

                // Capture the real exit code (non-blocking; child has already
                // closed stdout before the reader sets exited).
                let code = capture_exit_code(&mut s.child);
                s.last_exit_code = code;

                // Re-broadcast Exited with the real exit code so clients see it.
                // The reader's initial broadcast used None (it can't see the code).
                s.shared.broadcast(SessionEvent::Exited { exit_code: code });

                // Mark the in-flight turn errored and broadcast the delta.
                let delta = s
                    .shared
                    .transcript
                    .lock()
                    .unwrap()
                    .mark_current_errored("session process exited unexpectedly");
                if let Some(d) = delta {
                    s.shared.broadcast(SessionEvent::Delta(d));
                }
                s.shared.set_state(SessionState::Crashed);

                // Sliding-window bookkeeping: push this crash, evict stale entries.
                let now = Instant::now();
                s.crash_times.push_back(now);
                while s
                    .crash_times
                    .front()
                    .map(|t| t.elapsed().as_secs() >= RESTART_WINDOW_SECS)
                    .unwrap_or(false)
                {
                    s.crash_times.pop_front();
                }
            }

            // ── phase 3: decision ─────────────────────────────────────────────
            let wants_recovery;
            let guard_tripped;
            let exit_code;
            let is_stale;
            let crash_times_snapshot;
            {
                let s = self.sessions.get_mut(&tag).unwrap();
                let has_pending = !s.shared.pending.lock().unwrap().is_empty();
                wants_recovery = !s.attached_clients.is_empty() || has_pending;
                let crash_count = s.crash_times.len() as u32;
                guard_tripped = crash_count >= MAX_RESTARTS;
                exit_code = s.last_exit_code;
                crash_times_snapshot = s.crash_times.clone();
                // NOTE: tiny race — the stderr drain sets this flag in a separate
                // thread. It almost always fires before reap_and_recover ticks (the
                // process exits within milliseconds of writing to stderr), but is
                // not guaranteed. The worst case is one extra retry before the flag
                // is seen; the crash-loop guard still trips eventually.
                is_stale = s.stale_session_id.load(Ordering::SeqCst);
            }

            if wants_recovery && is_stale {
                // Permanent configuration error: the persisted session id is no
                // longer valid. Clear it and spawn a fresh conversation. Bypass
                // the crash-loop guard and backoff — this is not a misbehaving
                // process, it's a stale pointer we can deterministically fix in
                // one step.
                warn!(
                    tag,
                    "clearing stale session id and restarting with fresh session"
                );
                let (agent, view, cwd, rc, attached) = {
                    let s = self.sessions.get(&tag).unwrap();
                    (
                        s.agent_name.clone(),
                        s.view_name.clone(),
                        s.cwd.clone(),
                        s.remote_control,
                        s.attached_clients.iter().cloned().collect::<Vec<_>>(),
                    )
                };
                self.stop(&tag);
                self.sessions.remove(&tag);
                save_id(&self.store_path, &tag, None);
                match self.spawn_session(tag.to_string(), agent, view, cwd, None, rc) {
                    Ok(_) => {
                        for client_id in attached {
                            let _ = self.attach(&tag, &client_id);
                        }
                    }
                    Err(e) => warn!(tag, "fresh restart after stale id clear failed: {e:#}"),
                }
            } else if wants_recovery && guard_tripped {
                warn!(tag, "crash-loop guard tripped; leaving session crashed");
                // Prevent repeated recovery attempts: treat as intentional.
                // Set stop_reason = CrashLoopGuard and broadcast PermanentlyDown
                // so attached clients can show the alarm indicator.
                if let Some(s) = self.sessions.get_mut(&tag) {
                    s.intentional_stop.store(true, Ordering::SeqCst);
                    s.stop_reason = Some(StopReason::CrashLoopGuard);
                    s.shared.broadcast(SessionEvent::PermanentlyDown {
                        reason: StopReason::CrashLoopGuard,
                    });
                }
            } else if wants_recovery {
                // Exit-code-aware restart policy:
                //   exit 0 or signal (None) → restart immediately (clean shutdown).
                //   non-zero exit → transient error; apply exponential backoff.
                //   backoff already served → restart now regardless of code.
                let restart_now = exit_code == Some(0) || exit_code.is_none() || backoff_served;
                if restart_now {
                    warn!(
                        tag,
                        restart = crash_times_snapshot.len(),
                        exit_code = ?exit_code,
                        "auto-restarting crashed session"
                    );
                    if let Err(e) = self.restart(&tag) {
                        warn!(tag, "auto-restart failed: {e:#}");
                    } else if let Some(s) = self.sessions.get_mut(&tag) {
                        // Carry the crash window into the new session so the
                        // guard accumulates across restarts (the old fixed-window
                        // bug: restart() builds a fresh ManagedSession and resets
                        // the counter; this re-instates it).
                        s.crash_times = crash_times_snapshot;
                    }
                } else {
                    // Non-zero exit and no backoff already served: schedule one.
                    let crash_count = crash_times_snapshot.len() as u32;
                    let delay = backoff_delay(crash_count);
                    if let Some(s) = self.sessions.get_mut(&tag) {
                        s.restart_at = Some(Instant::now() + delay);
                        warn!(
                            tag,
                            exit_code = ?exit_code,
                            delay_secs = delay.as_secs(),
                            "crash exit; backing off before restart"
                        );
                    }
                }
            }
            // else: nobody wants recovery — leave it crashed (no-op).
        }
    }

    // ── list ──────────────────────────────────────────────────────────────────

    pub fn list(&self) -> Vec<SessionInfo> {
        self.sessions.values().map(|s| s.info()).collect()
    }

    /// Replace the focus registry with the Mac-pushed snapshot. Returns the new
    /// registry so the caller can broadcast it.
    pub fn set_focus_registry(&mut self, focuses: Vec<FocusMeta>) -> Vec<FocusMeta> {
        self.focus_registry = focuses;
        self.focus_registry.clone()
    }

    /// Current focus registry snapshot.
    pub fn focus_registry(&self) -> Vec<FocusMeta> {
        self.focus_registry.clone()
    }

    /// Whether `tag` currently has a live (non-exited) session child.
    pub fn has_live_session(&self, tag: &str) -> bool {
        self.sessions.get(tag).map(|s| s.alive()).unwrap_or(false)
    }

    /// Insert or replace a single focus in the registry (by `tag`), returning the
    /// updated registry so the caller can broadcast it. Used by the
    /// `create_focus` MCP tool, which adds an agent-spawned focus to the
    /// daemon-owned registry.
    pub fn add_or_update_focus(&mut self, meta: FocusMeta) -> Vec<FocusMeta> {
        if let Some(existing) = self.focus_registry.iter_mut().find(|f| f.tag == meta.tag) {
            *existing = meta;
        } else {
            self.focus_registry.push(meta);
        }
        self.focus_registry.clone()
    }

    // ── shutdown ────────────────────────────────────────────────────────────

    /// Kill all children. Called on SIGTERM.
    pub fn kill_all_on_shutdown(&mut self) {
        for (tag, session) in &mut self.sessions {
            session.intentional_stop.store(true, Ordering::SeqCst);
            let _ = session.child.kill();
            for (_, h) in session.forwarders.drain() {
                h.abort();
            }
            info!(tag = %tag, "session killed on shutdown");
        }
        self.sessions.clear();
    }

    /// Detach all of a disconnecting client's sessions (children keep running).
    pub fn on_client_disconnect(&mut self, client_id: &str) {
        for session in self.sessions.values_mut() {
            session.attached_clients.remove(client_id);
            if let Some(h) = session.forwarders.remove(client_id) {
                h.abort();
            }
        }
        self.client_senders.lock().unwrap().remove(client_id);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    fn send_to_client(&self, client_id: &str, msg: ServerMsg) {
        let senders = self.client_senders.lock().unwrap();
        if let Some(tx) = senders.get(client_id) {
            let _ = tx.send(msg);
        }
    }

    /// Broadcast a message to every currently connected client.
    fn send_to_all_clients(&self, msg: ServerMsg) {
        let senders = self.client_senders.lock().unwrap();
        for tx in senders.values() {
            let _ = tx.send(msg.clone());
        }
    }

    /// Scan all sessions for pending summary emissions.  Called from the
    /// supervisor tick immediately after `reap_and_recover`.  For each session
    /// whose `summary_sent` flag is still false, derives a summary from
    /// `turns[0].user_input` and broadcasts it to all clients.  The flag is
    /// set to `true` before the broadcast so a second tick is a no-op even if
    /// the send fails.
    pub fn emit_pending_summaries(&self) {
        for (tag, session) in &self.sessions {
            if session.summary_sent.load(Ordering::SeqCst) {
                continue;
            }
            let turns = session.shared.transcript.lock().unwrap().snapshot();
            if let Some(summary) = derive_summary(&turns) {
                session.summary_sent.store(true, Ordering::SeqCst);
                self.send_to_all_clients(ServerMsg::SessionSummaryUpdate {
                    tag: tag.clone(),
                    summary,
                });
            }
        }
    }

    #[cfg(test)]
    fn session_state(&self, tag: &str) -> Option<SessionState> {
        self.sessions.get(tag).map(|s| s.state())
    }
}

impl Default for SessionManager {
    fn default() -> Self {
        Self::new()
    }
}

// ── reader loop ───────────────────────────────────────────────────────────────

/// Blocking stdout reader: parse each line into the transcript, broadcast
/// deltas, drive turn state, drain the pending queue, and signal EOF.
fn run_reader(tag: String, stdout: std::process::ChildStdout, shared: Shared) {
    let reader = BufReader::new(stdout);
    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                debug!(tag = %tag, "session reader error: {e}");
                break;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        let deltas = shared.transcript.lock().unwrap().ingest_line(&line);
        for delta in deltas {
            match &delta {
                TurnDelta::TurnStarted { .. } => {
                    shared.set_state(SessionState::MidTurn);
                }
                TurnDelta::TurnCompleted { .. } | TurnDelta::TurnErrored { .. } => {
                    shared.broadcast(SessionEvent::Delta(delta.clone()));
                    drain_or_idle(&shared);
                    continue;
                }
                _ => {}
            }
            shared.broadcast(SessionEvent::Delta(delta));
        }
    }

    // stdout closed → child exited / stream ended. The reader can't see the
    // child's exit code (it owns only stdout); reap_and_recover captures the
    // real code via child.try_wait() and re-broadcasts Exited with it.
    shared.exited.store(true, Ordering::SeqCst);
    shared.broadcast(SessionEvent::Exited { exit_code: None });
    tracing::warn!(tag = %tag, "session reader EOF — child stdout closed (crash or clean exit)");
}

/// After a turn completes, send the next queued message (staying mid-turn) or
/// fall back to idle.
fn drain_or_idle(shared: &Shared) {
    let next = shared.pending.lock().unwrap().pop_front();
    match next {
        Some(msg) => {
            if write_user_frame(&shared.stdin, &msg.text, &msg.images).is_ok() {
                shared.set_state(SessionState::MidTurn);
            } else {
                shared.set_state(SessionState::Idle);
            }
        }
        None => shared.set_state(SessionState::Idle),
    }
}

// ── image encoding helpers ────────────────────────────────────────────────────

struct EncodedImage {
    media_type: String,
    base64_data: String,
}

fn media_type_for(path: &str) -> &'static str {
    match std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .as_deref()
    {
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        _ => "image/png",
    }
}

fn encode_images(paths: &[String]) -> Vec<EncodedImage> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    paths
        .iter()
        .filter_map(|p| match std::fs::read(p) {
            Ok(bytes) => Some(EncodedImage {
                media_type: media_type_for(p).to_string(),
                base64_data: STANDARD.encode(bytes),
            }),
            Err(e) => {
                tracing::warn!(path = %p, "skipping unreadable image: {e}");
                None
            }
        })
        .collect()
}

/// Write one stream-json user-message frame to the child's stdin.
/// When `images` is non-empty, emits array content (text block + image blocks);
/// when empty, emits a plain string — byte-identical to the pre-image wire format.
fn write_user_frame(
    stdin: &Arc<Mutex<Option<ChildStdin>>>,
    text: &str,
    images: &[String],
) -> Result<()> {
    let encoded = encode_images(images);
    let content = if encoded.is_empty() {
        serde_json::json!(text)
    } else {
        let mut blocks = vec![serde_json::json!({ "type": "text", "text": text })];
        for img in &encoded {
            blocks.push(serde_json::json!({
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": img.media_type,
                    "data": img.base64_data,
                }
            }));
        }
        serde_json::json!(blocks)
    };
    let frame = serde_json::json!({
        "type": "user",
        "message": { "role": "user", "content": content }
    });
    let mut line = serde_json::to_string(&frame)?;
    line.push('\n');

    let mut guard = stdin.lock().unwrap();
    let stdin = guard
        .as_mut()
        .ok_or_else(|| anyhow!("session stdin closed"))?;
    stdin.write_all(line.as_bytes())?;
    stdin.flush()?;
    Ok(())
}

// ── claude resolution + arg construction ──────────────────────────────────────

/// Exponential backoff for the nth transient restart. `crash_count` is the
/// number of crashes recorded in the current sliding window *including* the one
/// just observed (so the first transient restart waits BACKOFF_BASE_SECS).
/// Capped at BACKOFF_MAX_SECS.
fn backoff_delay(crash_count: u32) -> Duration {
    let exp = crash_count.saturating_sub(1).min(16); // guard against shift overflow
    let secs = BACKOFF_BASE_SECS
        .saturating_mul(1u64 << exp)
        .min(BACKOFF_MAX_SECS);
    Duration::from_secs(secs)
}

/// Non-blocking reap of a crashed child's exit code. Safe to call under the
/// manager mutex: `try_wait()` never blocks. Returns the numeric exit code if
/// the child exited with one, else `None` (killed by signal, already reaped,
/// or still winding down — by the time `exited` is set this is rare).
fn capture_exit_code(child: &mut Child) -> Option<i32> {
    match child.try_wait() {
        Ok(Some(status)) => status.code(),
        _ => None,
    }
}

/// Build the `claude` argument vector for a persistent stream-json session.
pub fn build_claude_args(
    agent_name: &str,
    view_name: &str,
    remote_control: bool,
    session_id: &str,
    resume: bool,
) -> Vec<String> {
    let mut args: Vec<String> = vec![
        // Full permission bypass for daemon-hosted sessions. A headless
        // stream-json session has no way to answer an interactive permission
        // prompt, so the softer `--settings {defaultMode:bypassPermissions}`
        // would dead-end on prompts it still raises (notably compound `a && b`
        // commands). `--dangerously-skip-permissions` skips the checks outright
        // — matching sessions.toml and the in-process TUI views — so agents
        // like Perri can run their gh/compound commands. Scoped to this child
        // process; never touches the operator's global ~/.claude/settings.json.
        "--dangerously-skip-permissions".into(),
        "--input-format".into(),
        "stream-json".into(),
        "--output-format".into(),
        "stream-json".into(),
        "--verbose".into(),
        // Re-emit stdin-origin user messages on stdout (tagged isReplay) so the
        // daemon renders every user message off the output stream.
        "--replay-user-messages".into(),
        "--agent".into(),
        agent_name.into(),
        "-n".into(),
        view_name.into(),
    ];
    if remote_control {
        args.push("--remote-control".into());
        args.push(view_name.into());
    }
    if resume {
        args.push("--resume".into());
        args.push(session_id.into());
    } else {
        args.push("--session-id".into());
        args.push(session_id.into());
    }
    args
}

/// Resolve the `claude` binary: `$NOSTROMO_CLAUDE_BIN`, then common install
/// locations (port of the Swift `findClaude`), then `which`.
pub fn resolve_claude() -> Result<PathBuf> {
    if let Ok(p) = std::env::var(CLAUDE_BIN_ENV) {
        if !p.is_empty() {
            return Ok(PathBuf::from(p));
        }
    }
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/"));
    let candidates = [
        PathBuf::from("/usr/local/bin/claude"),
        PathBuf::from("/opt/homebrew/bin/claude"),
        home.join(".npm/bin/claude"),
        home.join(".nvm/versions/node/current/bin/claude"),
        home.join(".nvm/versions/node/lts/bin/claude"),
        home.join(".local/bin/claude"),
    ];
    for c in candidates {
        if is_executable(&c) {
            return Ok(c);
        }
    }
    // Last resort: `which claude`.
    if let Ok(out) = Command::new("which").arg("claude").output() {
        if out.status.success() {
            let p = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !p.is_empty() {
                return Ok(PathBuf::from(p));
            }
        }
    }
    Err(anyhow!(
        "cannot find the `claude` binary (set {CLAUDE_BIN_ENV} or install Claude Code)"
    ))
}

fn is_executable(p: &std::path::Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(p)
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        p.is_file()
    }
}

/// Augment PATH so `claude` can find its node/helpers (mirror of the Swift env
/// augmentation).
fn augment_path(cmd: &mut Command) {
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/"));
    let extra = [
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/opt/homebrew/bin"),
        home.join(".npm/bin"),
        home.join(".nvm/versions/node/current/bin"),
    ];
    let mut path = std::env::var("PATH").unwrap_or_default();
    for e in extra {
        path.push(':');
        path.push_str(&e.to_string_lossy());
    }
    cmd.env("PATH", path);
}

// ── summary derivation ────────────────────────────────────────────────────────

/// Derive a short display summary from the first user turn.
///
/// - Collapses newlines and runs of whitespace to a single space.
/// - Returns `None` for empty / whitespace-only input.
/// - Truncates to 40 chars (by `char` count) with a `…` suffix if longer.
fn derive_summary(turns: &[Turn]) -> Option<String> {
    let raw = turns.first().map(|t| t.user_input.as_str())?;

    // Collapse all whitespace (including newlines) to single spaces, then trim.
    let collapsed: String = raw
        .chars()
        .map(|c| if c.is_whitespace() { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");

    if collapsed.is_empty() {
        return None;
    }

    // Truncate by Unicode scalar count (chars()), not bytes.
    const MAX_CHARS: usize = 40;
    if collapsed.chars().count() > MAX_CHARS {
        let truncated: String = collapsed.chars().take(MAX_CHARS).collect();
        Some(format!("{truncated}\u{2026}")) // U+2026 HORIZONTAL ELLIPSIS
    } else {
        Some(collapsed)
    }
}

// ── session-id store ────────────────────────────────────────────────────────

/// Daemon-owned `tag -> session_id` store path.
///
/// `~/.nostromo/daemon-sessions.json`. Kept separate from the Swift one-shot
/// fallback's `gui-sessions.json`; the Swift thin-client milestone reconciles
/// the two so a feature-flag flip doesn't fork the conversation.
pub fn default_store_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("daemon-sessions.json")
}

fn load_id_store(path: &std::path::Path) -> HashMap<String, String> {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// Serializes the read-modify-write of the id store so concurrent session
/// spawns can't clobber each other's entries (the store maps focus tag →
/// claude session_id, used to `--resume` a conversation).
static SAVE_ID_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn save_id(path: &std::path::Path, tag: &str, sid: Option<&str>) {
    // Hold the lock across the whole read-modify-write so two simultaneous
    // spawns serialize instead of racing (one reads stale, the other
    // overwrites and drops the first's entry). Recover from a poisoned lock
    // rather than panicking the daemon.
    let _guard = SAVE_ID_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut map = load_id_store(path);
    match sid {
        Some(s) => {
            map.insert(tag.to_string(), s.to_string());
        }
        None => {
            map.remove(tag);
        }
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(bytes) = serde_json::to_vec_pretty(&map) {
        // Atomic replace: write a sibling temp file, then rename over the
        // store. A crash mid-write leaves the temp file behind, never a
        // truncated/zero-byte store — so a resumable session_id is never
        // silently lost (which would make the next spawn start a fresh
        // conversation with no error). rename(2) within one dir is atomic.
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, &bytes).is_ok() && std::fs::rename(&tmp, path).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn tmp_store() -> PathBuf {
        let mut p = std::env::temp_dir();
        let unique = format!("nostromo-test-{}.json", Uuid::new_v4());
        p.push(unique);
        p
    }

    // ── derive_summary ────────────────────────────────────────────────────────

    fn make_turns(user_input: &str) -> Vec<Turn> {
        vec![Turn {
            id: "t0".into(),
            user_input: user_input.into(),
            timestamp: None,
            blocks: vec![],
            is_complete: false,
        }]
    }

    #[test]
    fn derive_summary_short_passthrough() {
        let turns = make_turns("Build the auth flow");
        assert_eq!(derive_summary(&turns), Some("Build the auth flow".into()));
    }

    #[test]
    fn derive_summary_exactly_40_chars_not_truncated() {
        // 40 chars — should pass through unchanged
        let input = "a".repeat(40);
        let turns = make_turns(&input);
        assert_eq!(derive_summary(&turns), Some(input));
    }

    #[test]
    fn derive_summary_41_chars_gets_ellipsis() {
        let input = "a".repeat(41);
        let turns = make_turns(&input);
        let result = derive_summary(&turns).unwrap();
        assert!(result.ends_with('\u{2026}'), "should end with ellipsis: {result:?}");
        // The truncated part is 40 chars + 1 ellipsis codepoint
        assert_eq!(result.chars().count(), 41);
    }

    #[test]
    fn derive_summary_collapses_newlines() {
        let turns = make_turns("Fix the bug\nin the login\r\nmodule");
        assert_eq!(derive_summary(&turns), Some("Fix the bug in the login module".into()));
    }

    #[test]
    fn derive_summary_collapses_extra_spaces() {
        let turns = make_turns("  lots   of   spaces  ");
        assert_eq!(derive_summary(&turns), Some("lots of spaces".into()));
    }

    #[test]
    fn derive_summary_empty_returns_none() {
        let turns = make_turns("");
        assert_eq!(derive_summary(&turns), None);
    }

    #[test]
    fn derive_summary_whitespace_only_returns_none() {
        let turns = make_turns("   \n\t\r\n   ");
        assert_eq!(derive_summary(&turns), None);
    }

    #[test]
    fn derive_summary_no_turns_returns_none() {
        assert_eq!(derive_summary(&[]), None);
    }

    // ── arg construction ──────────────────────────────────────────────────────

    #[test]
    fn args_fresh_session_uses_session_id_flag() {
        let args = build_claude_args("fred", "Fred", false, "sid-1", false);
        assert!(args.windows(2).any(|w| w == ["--session-id", "sid-1"]));
        assert!(!args.iter().any(|a| a == "--resume"));
        assert!(!args.iter().any(|a| a == "--remote-control"));
        // permission bypass + stream-json + replay always present.
        assert!(args.iter().any(|a| a == "--dangerously-skip-permissions"));
        assert!(args
            .windows(2)
            .any(|w| w == ["--input-format", "stream-json"]));
        assert!(args
            .windows(2)
            .any(|w| w == ["--output-format", "stream-json"]));
        assert!(args.iter().any(|a| a == "--replay-user-messages"));
        assert!(args.windows(2).any(|w| w == ["--agent", "fred"]));
        assert!(args.windows(2).any(|w| w == ["-n", "Fred"]));
    }

    #[test]
    fn args_resume_uses_resume_flag() {
        let args = build_claude_args("teri", "Teri", false, "sid-2", true);
        assert!(args.windows(2).any(|w| w == ["--resume", "sid-2"]));
        assert!(!args.iter().any(|a| a == "--session-id"));
    }

    #[test]
    fn args_remote_control_adds_flag() {
        let args = build_claude_args("perri", "Perri", true, "sid-3", false);
        assert!(args.windows(2).any(|w| w == ["--remote-control", "Perri"]));
    }

    // ── id store ────────────────────────────────────────────────────────────

    #[test]
    fn id_store_round_trips_and_clears() {
        let path = tmp_store();
        save_id(&path, "fred", Some("sid-xyz"));
        assert_eq!(
            load_id_store(&path).get("fred").map(String::as_str),
            Some("sid-xyz")
        );
        save_id(&path, "teri", Some("sid-teri"));
        assert_eq!(load_id_store(&path).len(), 2);
        save_id(&path, "fred", None);
        assert!(!load_id_store(&path).contains_key("fred"));
        assert_eq!(
            load_id_store(&path).get("teri").map(String::as_str),
            Some("sid-teri")
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn id_store_survives_concurrent_writes() {
        // Regression: concurrent spawns must not clobber each other's entries
        // (the read-modify-write is serialized) and the store is never left
        // truncated (atomic temp+rename). Hammer N threads each writing a
        // distinct tag at the same path; all entries must survive.
        let path = tmp_store();
        let n = 24;
        let handles: Vec<_> = (0..n)
            .map(|i| {
                let p = path.clone();
                std::thread::spawn(move || {
                    save_id(&p, &format!("focus-{i}"), Some(&format!("sid-{i}")));
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }
        let map = load_id_store(&path);
        assert_eq!(map.len(), n, "every concurrent write must be preserved");
        for i in 0..n {
            assert_eq!(
                map.get(&format!("focus-{i}")).map(String::as_str),
                Some(format!("sid-{i}").as_str())
            );
        }
        // No stray temp file left behind.
        assert!(
            !path.with_extension("json.tmp").exists(),
            "temp file must be renamed away"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn resolve_claude_honours_env_override() {
        std::env::set_var(CLAUDE_BIN_ENV, "/custom/path/to/claude");
        let p = resolve_claude().unwrap();
        assert_eq!(p, PathBuf::from("/custom/path/to/claude"));
        std::env::remove_var(CLAUDE_BIN_ENV);
    }

    // ── manager mechanics with a stub child ───────────────────────────────────
    //
    // These tests drive the reader → transcript → broadcast → exit path with a
    // stub `sh -c` program emitting canned stream-json, so they exercise the
    // real process/pipe/thread machinery without `claude` or the network.

    /// Spawn a stub session that prints `script` to stdout then exits. The
    /// fixed program (`/bin/sh -c <script>`) is also recorded as the respawn
    /// spec so an auto-restart re-runs the stub rather than the real `claude`.
    fn spawn_stub(mgr: &mut SessionManager, tag: &str, script: &str) {
        let program = PathBuf::from("/bin/sh");
        let args = vec!["-c".to_string(), script.to_string()];
        let managed = mgr
            .spawn_managed(
                tag.to_string(),
                "agent".into(),
                "View".into(),
                None,
                false,
                "stub-sid".into(),
                false,
                program.clone(),
                args.clone(),
                Some((program, args)),
            )
            .expect("spawn stub");
        mgr.sessions.insert(tag.to_string(), managed);
    }

    async fn collect_events(
        rx: &mut broadcast::Receiver<SessionEvent>,
        max: usize,
    ) -> Vec<SessionEvent> {
        let mut out = vec![];
        for _ in 0..max {
            match tokio::time::timeout(Duration::from_secs(5), rx.recv()).await {
                Ok(Ok(ev)) => {
                    let done = matches!(ev, SessionEvent::Exited { .. });
                    out.push(ev);
                    if done {
                        break;
                    }
                }
                _ => break,
            }
        }
        out
    }

    #[tokio::test]
    async fn stub_session_streams_turn_then_exits() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // One turn: replayed user message + assistant text + result, then EOF.
        let script = r#"printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"},"isReplay":true}' '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0.01}'"#;
        let mut rx = {
            spawn_stub(&mut mgr, "fred", script);
            mgr.sessions
                .get("fred")
                .unwrap()
                .shared
                .event_tx
                .subscribe()
        };

        let events = collect_events(&mut rx, 20).await;

        // Must see a TurnStarted, a BlockAppended(text), a TurnCompleted, and Exited.
        let has_started = events
            .iter()
            .any(|e| matches!(e, SessionEvent::Delta(TurnDelta::TurnStarted { .. })));
        let has_completed = events
            .iter()
            .any(|e| matches!(e, SessionEvent::Delta(TurnDelta::TurnCompleted { .. })));
        let has_exit = events
            .iter()
            .any(|e| matches!(e, SessionEvent::Exited { .. }));
        assert!(has_started, "expected TurnStarted: {events:?}");
        assert!(has_completed, "expected TurnCompleted: {events:?}");
        assert!(has_exit, "expected Exited: {events:?}");

        // The transcript holds one completed turn.
        let turns = mgr
            .sessions
            .get("fred")
            .unwrap()
            .shared
            .transcript
            .lock()
            .unwrap()
            .snapshot();
        assert_eq!(turns.len(), 1);
        assert!(turns[0].is_complete);
        assert_eq!(turns[0].user_input, "hi");
    }

    #[tokio::test]
    async fn attach_delivers_snapshot_then_state() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        let script = r#"printf '%s\n' '{"type":"user","message":{"role":"user","content":"q"},"isReplay":true}' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}'; sleep 1"#;
        spawn_stub(&mut mgr, "teri", script);

        // Register a client sender, then attach.
        let (tx, mut crx) = mpsc::unbounded_channel::<ServerMsg>();
        mgr.client_senders.lock().unwrap().insert("c1".into(), tx);

        // Give the reader a moment to process the first turn.
        tokio::time::sleep(Duration::from_millis(300)).await;
        mgr.attach("teri", "c1").unwrap();

        // First two targeted messages must be SessionTurns then SessionState.
        let m1 = tokio::time::timeout(Duration::from_secs(2), crx.recv())
            .await
            .unwrap()
            .unwrap();
        let m2 = tokio::time::timeout(Duration::from_secs(2), crx.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(
            matches!(m1, ServerMsg::SessionTurns { .. }),
            "first msg {m1:?}"
        );
        assert!(
            matches!(m2, ServerMsg::SessionState { .. }),
            "second msg {m2:?}"
        );
    }

    // ── backoff and crash-loop guard tests ───────────────────────────────────

    #[test]
    fn backoff_delay_is_exponential_and_capped() {
        assert_eq!(backoff_delay(1), Duration::from_secs(1));
        assert_eq!(backoff_delay(2), Duration::from_secs(2));
        assert_eq!(backoff_delay(3), Duration::from_secs(4));
        // Large count saturates at BACKOFF_MAX_SECS.
        assert_eq!(backoff_delay(50), Duration::from_secs(BACKOFF_MAX_SECS));
    }

    #[tokio::test]
    async fn nonzero_exit_schedules_backoff_before_restart() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // exit 1 → non-zero exit → should schedule backoff, not restart immediately.
        spawn_stub(&mut mgr, "crashy1", "exit 1");
        mgr.sessions
            .get_mut("crashy1")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        tokio::time::sleep(Duration::from_millis(200)).await;

        // First reap: should record the crash and schedule backoff.
        mgr.reap_and_recover();

        let s = mgr.sessions.get("crashy1").expect("session still tracked");
        // Backoff must be scheduled (restart_at is Some).
        assert!(
            s.restart_at.is_some(),
            "non-zero exit should schedule a backoff deadline"
        );
        // Exactly one crash in the sliding window.
        assert_eq!(
            s.crash_times.len(),
            1,
            "one crash should be recorded in sliding window"
        );
        // Child was NOT restarted yet (exited flag still true — no new child spawned).
        assert!(
            s.shared.exited.load(Ordering::SeqCst),
            "session should remain crashed (not restarted) during backoff"
        );
    }

    #[tokio::test]
    async fn zero_exit_restarts_immediately() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // exit 0 → clean shutdown → should restart immediately, no backoff.
        spawn_stub(&mut mgr, "clean", "exit 0");
        mgr.sessions
            .get_mut("clean")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        tokio::time::sleep(Duration::from_millis(200)).await;

        // First reap: should restart immediately (no backoff for clean exit).
        mgr.reap_and_recover();

        let s = mgr.sessions.get("clean").expect("session still tracked");
        // No backoff should be scheduled.
        assert!(
            s.restart_at.is_none(),
            "clean exit should not schedule backoff"
        );
        // Crash window carries one entry (from the first crash, preserved across restart).
        assert_eq!(
            s.crash_times.len(),
            1,
            "crash window should survive restart with one entry"
        );
    }

    #[tokio::test]
    async fn exit_code_is_captured_and_broadcast() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "exitcode", "exit 1");
        let mut rx = mgr
            .sessions
            .get("exitcode")
            .unwrap()
            .shared
            .event_tx
            .subscribe();
        mgr.sessions
            .get_mut("exitcode")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        tokio::time::sleep(Duration::from_millis(200)).await;

        mgr.reap_and_recover();

        // The re-broadcast from reap_and_recover should carry exit_code: Some(1).
        // Drain events (timeout generously) looking for it.
        let mut found = false;
        for _ in 0..20 {
            match tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
                Ok(Ok(SessionEvent::Exited { exit_code: Some(1) })) => {
                    found = true;
                    break;
                }
                Ok(Ok(_)) => continue,
                _ => break,
            }
        }

        // Fallback: check the field directly (deterministic once try_wait has reaped).
        let s = mgr.sessions.get("exitcode").expect("session still tracked");
        let field_code = s.last_exit_code;

        assert!(
            found || field_code == Some(1),
            "exit code 1 should be captured (broadcast found={found}, field={field_code:?})"
        );
    }

    #[tokio::test]
    async fn sliding_window_guard_trips_and_survives_restart() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // "true" exits with code 0 → immediate restart, no backoff wait → fast test.
        spawn_stub(&mut mgr, "crashy", "true");
        mgr.sessions
            .get_mut("crashy")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        // Let the child exit.
        tokio::time::sleep(Duration::from_millis(200)).await;

        // Drive reap/sleep cycles: MAX_RESTARTS crashes trip the guard.
        // Each cycle: crash detected → restart (code 0) → new child exits quickly.
        for _ in 0..(MAX_RESTARTS + 2) {
            mgr.reap_and_recover();
            tokio::time::sleep(Duration::from_millis(150)).await;
        }

        let s = mgr.sessions.get("crashy").expect("session still tracked");
        // Guard must have tripped: intentional_stop is set.
        assert!(
            s.intentional_stop.load(Ordering::SeqCst),
            "guard should mark the session to stop retrying"
        );
        // Crash window must have reached MAX_RESTARTS — proving the window
        // survived across restarts (the bug we're fixing).
        assert_eq!(
            s.crash_times.len() as u32,
            MAX_RESTARTS,
            "sliding window should accumulate MAX_RESTARTS crashes across restarts"
        );
    }

    #[tokio::test]
    async fn second_send_queues_while_mid_turn() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // Long-lived stub that ignores stdin; stays Idle until we send.
        spawn_stub(&mut mgr, "q", "sleep 5");

        // First send (idle → writes, optimistically MidTurn).
        mgr.send_user_message("q", "first", &[]).unwrap();
        assert_eq!(mgr.session_state("q"), Some(SessionState::MidTurn));

        // Second send while mid-turn → queued, not written.
        mgr.send_user_message("q", "second", &[]).unwrap();
        let pending = mgr
            .sessions
            .get("q")
            .unwrap()
            .shared
            .pending
            .lock()
            .unwrap();
        assert_eq!(pending.len(), 1, "second message must queue while mid-turn");
        assert_eq!(pending.front().map(|m| m.text.as_str()), Some("second"));
    }

    #[tokio::test]
    async fn send_to_dead_session_errors() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "d", "true"); // exits immediately
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(mgr.send_user_message("d", "hi", &[]).is_err());
        assert!(mgr.send_user_message("missing", "hi", &[]).is_err());
    }

    #[tokio::test]
    async fn stop_marks_session_not_alive() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "longlived", "sleep 30");
        assert!(mgr.sessions.get("longlived").unwrap().alive());
        mgr.stop("longlived");
        assert!(!mgr.sessions.get("longlived").unwrap().alive());
        assert_eq!(mgr.session_state("longlived"), Some(SessionState::Idle));
    }

    // ── StopReason / PermanentlyDown ─────────────────────────────────────────

    #[tokio::test]
    async fn stop_sets_stop_reason_and_broadcasts_permanently_down() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "target", "sleep 30");
        let mut rx = mgr
            .sessions
            .get("target")
            .unwrap()
            .shared
            .event_tx
            .subscribe();

        mgr.stop("target");

        assert_eq!(
            mgr.sessions.get("target").unwrap().stop_reason,
            Some(StopReason::User),
            "stop() must set stop_reason to StopReason::User"
        );

        // Drain events looking for PermanentlyDown { reason: User }.
        let mut found = false;
        for _ in 0..20 {
            match tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
                Ok(Ok(SessionEvent::PermanentlyDown {
                    reason: StopReason::User,
                })) => {
                    found = true;
                    break;
                }
                Ok(Ok(_)) => continue,
                _ => break,
            }
        }
        assert!(
            found,
            "stop() must broadcast SessionEvent::PermanentlyDown {{ reason: User }}"
        );
    }

    #[tokio::test]
    async fn guard_trip_sets_stop_reason_and_broadcasts_permanently_down() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "crashy2", "true");
        mgr.sessions
            .get_mut("crashy2")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        // Let the initial child exit.
        tokio::time::sleep(Duration::from_millis(200)).await;

        // Run MAX_RESTARTS - 1 reap cycles to accumulate (MAX_RESTARTS - 1) crashes
        // with restarts (exit 0 → immediate restart). Each restart creates a new
        // ManagedSession with a new event_tx — so we must subscribe AFTER the last
        // restart and BEFORE the trip to capture the PermanentlyDown broadcast.
        for _ in 0..(MAX_RESTARTS - 1) {
            mgr.reap_and_recover();
            tokio::time::sleep(Duration::from_millis(150)).await;
        }

        // Subscribe to the CURRENT session's event_tx. The guard will trip on the
        // very next reap (one more crash reaches MAX_RESTARTS), broadcasting on this
        // channel.
        let mut rx = mgr
            .sessions
            .get("crashy2")
            .unwrap()
            .shared
            .event_tx
            .subscribe();

        // One more reap → guard trips → broadcasts PermanentlyDown on rx.
        mgr.reap_and_recover();
        tokio::time::sleep(Duration::from_millis(150)).await;

        // Assert durable state: stop_reason == CrashLoopGuard.
        let s = mgr.sessions.get("crashy2").expect("session still tracked");
        assert_eq!(
            s.stop_reason,
            Some(StopReason::CrashLoopGuard),
            "crash-loop guard trip must set stop_reason to CrashLoopGuard"
        );

        // Drain rx for PermanentlyDown { reason: CrashLoopGuard }.
        let mut found = false;
        for _ in 0..40 {
            match tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
                Ok(Ok(SessionEvent::PermanentlyDown {
                    reason: StopReason::CrashLoopGuard,
                })) => {
                    found = true;
                    break;
                }
                Ok(Ok(_)) => continue,
                _ => break,
            }
        }
        assert!(
            found,
            "guard trip must broadcast SessionEvent::PermanentlyDown {{ reason: CrashLoopGuard }}"
        );
    }

    #[tokio::test]
    async fn restart_clears_stop_reason_and_crash_window() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "crashy3", "true");
        mgr.sessions
            .get_mut("crashy3")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        tokio::time::sleep(Duration::from_millis(200)).await;

        // Trip the guard.
        for _ in 0..(MAX_RESTARTS + 2) {
            mgr.reap_and_recover();
            tokio::time::sleep(Duration::from_millis(150)).await;
        }

        assert_eq!(
            mgr.sessions.get("crashy3").unwrap().stop_reason,
            Some(StopReason::CrashLoopGuard),
            "guard must have tripped before restart"
        );

        // User-initiated restart — should build a fresh ManagedSession.
        mgr.restart("crashy3").unwrap();

        let s = mgr
            .sessions
            .get("crashy3")
            .expect("session present after restart");
        assert_eq!(
            s.stop_reason, None,
            "restarted session must have stop_reason == None"
        );
        assert!(
            s.crash_times.is_empty(),
            "restarted session must have an empty crash window"
        );
        assert!(s.alive(), "restarted session must be alive");
    }
}
