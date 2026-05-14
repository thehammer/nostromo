//! `DaemonPtyClient` — TUI-side handle to a daemon-owned PTY.
//!
//! Mirrors the public surface of [`PtyHost`] so views can hold either through
//! [`PtyBackend`] without caring which variant is in use.
//!
//! ## Lifecycle
//!
//! `DaemonPtyClient::spawn_new` sends `PtySpawn` + `PtyAttach` to the daemon
//! and starts a background task that feeds incoming `PtyScrollback` /
//! `PtyOutput` chunks into a local `vt100::Parser`.
//!
//! `DaemonPtyClient::attach_existing` sends only `PtyAttach`; the daemon
//! responds with `PtyAttached` + `PtyScrollback` to replay history.
//!
//! `Drop` sends `PtyDetach` (PTY keeps running in the daemon).
//! `kill()` sends `PtyKill` (daemon kills the child process).

use std::sync::{Arc, Mutex};

use crossterm::event::KeyEvent;
use tokio::sync::broadcast;
use tokio::sync::mpsc;
use tracing::{debug, warn};
use uuid::Uuid;

use crate::{
    event::AppEvent,
    ipc::{
        protocol::{ClientMsg, ServerMsg},
        DaemonClient,
    },
    mcp::state::{McpSharedState, PtyIdentity},
    pty::keys::key_to_bytes,
};

/// A TUI-side handle to a PTY that lives inside the daemon.
pub struct DaemonPtyClient {
    pty_id: String,
    client: DaemonClient,
    pub parser: Arc<Mutex<vt100::Parser>>,
    size: (u16, u16),
    _reader_task: tokio::task::JoinHandle<()>,
    /// `NOSTROMO_PTY_ID` injected into the daemon-side child process.
    /// `None` until the `PtyIdentity` follow-up is received.
    nostromo_pty_id: Arc<Mutex<Option<String>>>,
    /// Shared MCP state; used on Drop to deregister the PTY.
    mcp_state: Option<Arc<McpSharedState>>,
}

impl DaemonPtyClient {
    // ── constructors ─────────────────────────────────────────────────────────

    /// Spawn a brand-new PTY in the daemon and attach to it.
    ///
    /// Returns immediately; the background task populates the parser as data
    /// arrives (same as `PtyHost`).
    pub fn spawn_new(
        client: DaemonClient,
        cmd: &str,
        args: &[&str],
        (cols, rows): (u16, u16),
        event_tx: mpsc::UnboundedSender<AppEvent>,
        view_id: &'static str,
        client_tag: &str,
    ) -> Self {
        Self::spawn_new_with_mcp(client, cmd, args, (cols, rows), event_tx, view_id, client_tag, None)
    }

    /// Like [`spawn_new`] but registers the PTY with `mcp_state` when the
    /// `PtyIdentity` follow-up message arrives from the daemon.
    pub fn spawn_new_with_mcp(
        client: DaemonClient,
        cmd: &str,
        args: &[&str],
        (cols, rows): (u16, u16),
        event_tx: mpsc::UnboundedSender<AppEvent>,
        view_id: &'static str,
        client_tag: &str,
        mcp_state: Option<Arc<McpSharedState>>,
    ) -> Self {
        let pty_id = Uuid::new_v4().to_string();
        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, 1000)));
        let nostromo_pty_id: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

        // Subscribe BEFORE sending PtySpawn so we cannot miss the PtySpawned
        // response if the daemon replies before the subscriber is registered.
        let mut rx = client.subscribe();

        // Send PtySpawn.
        let _ = client.send(ClientMsg::PtySpawn {
            pty_id: pty_id.clone(),
            cmd: cmd.to_string(),
            args: args.iter().map(|s| s.to_string()).collect(),
            cols,
            rows,
            cwd: std::env::current_dir().ok(),
            client_tag: client_tag.to_string(),
        });

        // Background task: wait for PtySpawned → (PtyIdentity) → PtyAttach → stream output.
        let client_clone = client.clone();
        let parser_clone = Arc::clone(&parser);
        let nostromo_pty_id_clone = Arc::clone(&nostromo_pty_id);
        // Clone mcp_state for the background task; original is kept for the struct.
        let mcp_state_for_task = mcp_state.clone();

        let reader_task = tokio::spawn(async move {
            let mcp_state = mcp_state_for_task;
            // Wait for PtySpawned.
            let spawned_id = loop {
                match rx.recv().await {
                    Ok(ServerMsg::PtySpawned { pty_id }) => break pty_id,
                    Ok(ServerMsg::Error { message }) => {
                        warn!(view_id, "PtySpawn error: {message}");
                        return;
                    }
                    Ok(_) => continue,
                    Err(_) => return,
                }
            };

            // Opportunistically wait a short time for the PtyIdentity follow-up.
            // The daemon sends it immediately after PtySpawned so this window is
            // always sufficient; we don't block the attach if it doesn't arrive.
            let deadline = tokio::time::Instant::now()
                + tokio::time::Duration::from_millis(100);
            if let Ok(Ok(ServerMsg::PtyIdentity {
                pty_id: identity_pty_id,
                nostromo_pty_id: nid,
                nostromo_session_id: sid,
            })) = tokio::time::timeout_at(deadline, rx.recv()).await
            {
                if identity_pty_id == spawned_id {
                    *nostromo_pty_id_clone.lock().unwrap() = Some(nid.clone());
                    if let Some(ref state) = mcp_state {
                        state
                            .register_pty(
                                nid,
                                PtyIdentity {
                                    view_id,
                                    session_id: sid,
                                    spawned_at: std::time::SystemTime::now(),
                                },
                            )
                            .await;
                    }
                }
            }

            // Attach.
            let _ = client_clone.send(ClientMsg::PtyAttach {
                pty_id: spawned_id.clone(),
            });

            // Stream output.
            run_output_loop(&spawned_id, rx, parser_clone, event_tx, view_id).await;
        });

        Self {
            pty_id,
            client,
            parser,
            size: (cols, rows),
            _reader_task: reader_task,
            nostromo_pty_id,
            mcp_state,
        }
    }

    /// Attach to an existing daemon PTY (reattach after TUI restart).
    ///
    /// The daemon sends `PtyAttached` + `PtyScrollback` to replay history
    /// before streaming live output.
    pub fn attach_existing(
        client: DaemonClient,
        pty_id: String,
        (cols, rows): (u16, u16),
        event_tx: mpsc::UnboundedSender<AppEvent>,
        view_id: &'static str,
    ) -> Self {
        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, 1000)));

        // Send PtyAttach immediately.
        let _ = client.send(ClientMsg::PtyAttach {
            pty_id: pty_id.clone(),
        });

        let mut rx = client.subscribe();
        let pty_id_clone = pty_id.clone();
        let parser_clone = Arc::clone(&parser);

        let reader_task = tokio::spawn(async move {
            // Wait for PtyAttached to learn the canonical size.
            loop {
                match rx.recv().await {
                    Ok(ServerMsg::PtyAttached { pty_id, .. }) if pty_id == pty_id_clone => break,
                    Ok(_) => continue,
                    Err(_) => return,
                }
            }

            run_output_loop(&pty_id_clone, rx, parser_clone, event_tx, view_id).await;
        });

        Self {
            pty_id,
            client,
            parser,
            size: (cols, rows),
            _reader_task: reader_task,
            nostromo_pty_id: Arc::new(Mutex::new(None)),
            mcp_state: None,
        }
    }

    // ── public interface (mirrors PtyHost) ────────────────────────────────────

    pub fn resize(&mut self, cols: u16, rows: u16) {
        if (cols, rows) == self.size {
            return;
        }
        self.size = (cols, rows);
        let _ = self.client.send(ClientMsg::PtyResize {
            pty_id: self.pty_id.clone(),
            cols,
            rows,
        });
    }

    pub fn send_key(&mut self, key: &KeyEvent) {
        if let Some(bytes) = key_to_bytes(key) {
            let _ = self.client.send(ClientMsg::PtyInput {
                pty_id: self.pty_id.clone(),
                bytes,
            });
        }
    }

    pub fn size(&self) -> (u16, u16) {
        self.size
    }

    /// Explicitly kill the child process in the daemon.
    pub fn kill(&self) {
        let _ = self.client.send(ClientMsg::PtyKill {
            pty_id: self.pty_id.clone(),
        });
    }
}

impl Drop for DaemonPtyClient {
    fn drop(&mut self) {
        // Detach (not kill) — PTY keeps running in the daemon.
        let _ = self.client.send(ClientMsg::PtyDetach {
            pty_id: self.pty_id.clone(),
        });
        debug!(pty_id = %self.pty_id, "DaemonPtyClient dropped; sent PtyDetach");

        // Deregister from MCP state if we have a nostromo_pty_id.
        if let Some(state) = self.mcp_state.take() {
            if let Some(nid) = self.nostromo_pty_id.lock().unwrap().clone() {
                tokio::spawn(async move {
                    state.deregister_pty(&nid).await;
                });
            }
        }
    }
}

// ── output streaming loop ────────────────────────────────────────────────────

/// Feed `PtyScrollback` then `PtyOutput` chunks for `pty_id` into `parser`.
async fn run_output_loop(
    pty_id: &str,
    mut rx: broadcast::Receiver<ServerMsg>,
    parser: Arc<Mutex<vt100::Parser>>,
    event_tx: mpsc::UnboundedSender<AppEvent>,
    view_id: &'static str,
) {
    loop {
        match rx.recv().await {
            Ok(ServerMsg::PtyScrollback { pty_id: id, bytes }) if id == pty_id => {
                parser.lock().unwrap().process(&bytes);
                let _ = event_tx.send(AppEvent::AgentUpdate { view_id });
            }
            Ok(ServerMsg::PtyOutput { pty_id: id, bytes }) if id == pty_id => {
                parser.lock().unwrap().process(&bytes);
                let _ = event_tx.send(AppEvent::AgentUpdate { view_id });
            }
            Ok(ServerMsg::PtyExited { pty_id: id, .. }) if id == pty_id => {
                debug!(pty_id, "PTY exited");
                break;
            }
            Ok(ServerMsg::PtyDetach { pty_id: id }) if id == pty_id => {
                // Another client stole attach; stop streaming.
                debug!(pty_id, "received PtyDetach; stopping output loop");
                break;
            }
            Ok(_) => continue,
            Err(broadcast::error::RecvError::Lagged(n)) => {
                warn!(pty_id, "daemon client lagged {n} messages");
            }
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}

// ── PtyFactory ────────────────────────────────────────────────────────────────

use crate::ipc::protocol::PtyInfo;

/// Factory abstraction for spawning PTYs.
///
/// Views hold `Arc<dyn PtyFactory>` via `ViewCtx` without caring whether PTYs
/// live in-process or in the daemon.
pub trait PtyFactory: Send + Sync {
    /// Spawn (or reuse via reattach) a PTY for the given view.
    fn spawn(
        &self,
        view_tag: &'static str,
        cmd: &str,
        args: &[&str],
        size: (u16, u16),
        tx: mpsc::UnboundedSender<AppEvent>,
    ) -> anyhow::Result<crate::pty::PtyBackend>;

    /// Return live PTYs whose `client_tag` matches `view_tag`.
    ///
    /// Always empty for the in-process factory.
    fn list_existing(&self, view_tag: &str) -> Vec<PtyInfo>;

    /// Attach to an existing PTY by id.
    fn attach(
        &self,
        pty_id: &str,
        size: (u16, u16),
        tx: mpsc::UnboundedSender<AppEvent>,
        view_tag: &'static str,
    ) -> anyhow::Result<crate::pty::PtyBackend>;
}

// ── InProcessPtyFactory ───────────────────────────────────────────────────────

/// Factory that creates in-process `PtyHost` instances (daemon not available).
pub struct InProcessPtyFactory {
    /// Shared MCP state.  PTYs spawned by this factory are registered here.
    pub mcp_state: Arc<McpSharedState>,
}

impl InProcessPtyFactory {
    pub fn new(mcp_state: Arc<McpSharedState>) -> Self {
        Self { mcp_state }
    }
}

impl PtyFactory for InProcessPtyFactory {
    fn spawn(
        &self,
        view_tag: &'static str,
        cmd: &str,
        args: &[&str],
        size: (u16, u16),
        tx: mpsc::UnboundedSender<AppEvent>,
    ) -> anyhow::Result<crate::pty::PtyBackend> {
        let host = crate::pty::PtyHost::spawn_with_mcp(
            cmd,
            args,
            size,
            tx,
            view_tag,
            Arc::clone(&self.mcp_state),
        )?;
        Ok(crate::pty::PtyBackend::InProcess(host))
    }

    fn list_existing(&self, _view_tag: &str) -> Vec<PtyInfo> {
        vec![]
    }

    fn attach(
        &self,
        _pty_id: &str,
        _size: (u16, u16),
        _tx: mpsc::UnboundedSender<AppEvent>,
        _view_tag: &'static str,
    ) -> anyhow::Result<crate::pty::PtyBackend> {
        anyhow::bail!("in-process factory does not support attach")
    }
}

// ── DaemonPtyFactory ──────────────────────────────────────────────────────────

/// Factory that spawns/attaches PTYs via the daemon.
pub struct DaemonPtyFactory {
    client: DaemonClient,
    /// Cached PTY list from last `refresh_existing` call.
    existing: Arc<Mutex<Vec<PtyInfo>>>,
    /// Shared MCP state.  PTYs spawned by this factory are registered here.
    pub mcp_state: Arc<McpSharedState>,
}

impl DaemonPtyFactory {
    /// Create factory and pre-fetch the existing PTY list from the daemon.
    pub async fn new_with_refresh(client: DaemonClient, mcp_state: Arc<McpSharedState>) -> Self {
        let factory = Self {
            client,
            existing: Arc::new(Mutex::new(vec![])),
            mcp_state,
        };
        factory.refresh_existing().await;
        factory
    }

    /// Ask the daemon for its current PTY list and cache it.
    pub async fn refresh_existing(&self) {
        let mut rx = self.client.subscribe();
        if self.client.send(ClientMsg::PtyList).is_err() {
            return;
        }
        // Wait briefly for PtyListResp.
        let deadline = tokio::time::Instant::now() + tokio::time::Duration::from_millis(500);
        loop {
            match tokio::time::timeout_at(deadline, rx.recv()).await {
                Ok(Ok(ServerMsg::PtyListResp { ptys })) => {
                    *self.existing.lock().unwrap() = ptys;
                    break;
                }
                Ok(Ok(_)) => continue,
                _ => break,
            }
        }
    }
}

impl PtyFactory for DaemonPtyFactory {
    fn spawn(
        &self,
        view_tag: &'static str,
        cmd: &str,
        args: &[&str],
        size: (u16, u16),
        tx: mpsc::UnboundedSender<AppEvent>,
    ) -> anyhow::Result<crate::pty::PtyBackend> {
        let daemon_client = DaemonPtyClient::spawn_new_with_mcp(
            self.client.clone(),
            cmd,
            args,
            size,
            tx,
            view_tag,
            view_tag,
            Some(Arc::clone(&self.mcp_state)),
        );
        Ok(crate::pty::PtyBackend::Daemon(daemon_client))
    }

    fn list_existing(&self, view_tag: &str) -> Vec<PtyInfo> {
        self.existing
            .lock()
            .unwrap()
            .iter()
            .filter(|p| p.alive && p.client_tag == view_tag)
            .cloned()
            .collect()
    }

    fn attach(
        &self,
        pty_id: &str,
        size: (u16, u16),
        tx: mpsc::UnboundedSender<AppEvent>,
        view_tag: &'static str,
    ) -> anyhow::Result<crate::pty::PtyBackend> {
        let daemon_client = DaemonPtyClient::attach_existing(
            self.client.clone(),
            pty_id.to_string(),
            size,
            tx,
            view_tag,
        );
        Ok(crate::pty::PtyBackend::Daemon(daemon_client))
    }
}
