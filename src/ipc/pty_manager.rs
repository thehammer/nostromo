//! Daemon-side PTY manager.
//!
//! `PtyManager` owns all PTY child processes on behalf of `nostromd`.  Each
//! PTY keeps running when the TUI disconnects; a new TUI session can reattach
//! and replay scrollback before resuming live output.
//!
//! ## Attach semantics
//!
//! Only one client may be attached to a given PTY at a time.  A second
//! `PtyAttach` for an already-attached PTY first sends `PtyDetach` to the
//! incumbent client before handing control to the new one.
//!
//! ## Output fan-out
//!
//! Each PTY runs a `spawn_blocking` reader that broadcasts `PtyChunk` values.
//! An attached-client forwarder task subscribes to that broadcast, converts
//! chunks to `ServerMsg::PtyOutput` / `ServerMsg::PtyExited`, and writes them
//! via the client's per-connection `UnboundedSender<ServerMsg>`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use anyhow::Result;
use portable_pty::{CommandBuilder, PtySize};
use tokio::sync::{broadcast, mpsc};
use tracing::{debug, info, warn};

use super::{
    protocol::{PtyInfo, ServerMsg},
    scrollback::ScrollbackBuf,
};

// ── PTY chunk ─────────────────────────────────────────────────────────────────

/// Output unit broadcast by a PTY's reader task.
#[derive(Debug, Clone)]
pub enum PtyChunk {
    /// Raw bytes from the child process.
    Bytes(Vec<u8>),
    /// Child process exited (no more data).
    Exited { exit_code: Option<i32> },
}

// ── managed PTY ───────────────────────────────────────────────────────────────

struct ManagedPty {
    writer: Box<dyn std::io::Write + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
    scrollback: Arc<Mutex<ScrollbackBuf>>,
    /// Broadcast for live PTY output.  Subscribers get `PtyChunk`.
    output_tx: broadcast::Sender<PtyChunk>,
    alive: bool,
    cols: u16,
    rows: u16,
    master: Box<dyn portable_pty::MasterPty + Send>,
    cmd: String,
    args: Vec<String>,
    last_activity: SystemTime,
    client_tag: String,
    /// Client id that has an active attach.
    attached_client: Option<String>,
    /// Abort handle for the active forwarder task.
    forwarder_handle: Option<tokio::task::AbortHandle>,
    /// Reader task (keep alive until PTY exits).
    _reader_task: tokio::task::JoinHandle<()>,
}

// SAFETY: ManagedPty is only accessed under PtyManager's Mutex.
unsafe impl Send for ManagedPty {}
unsafe impl Sync for ManagedPty {}

// ── PtyManager ────────────────────────────────────────────────────────────────

/// Shared daemon-side registry of running PTYs.
///
/// All public methods take `&mut self` — callers hold the wrapping Mutex.
pub struct PtyManager {
    ptys: HashMap<String, ManagedPty>,
    /// Per-connected-client senders for targeted messages.
    /// Registered by the server's `handle_client` loop.
    client_senders: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<ServerMsg>>>>,
}

impl PtyManager {
    pub fn new() -> Self {
        Self {
            ptys: HashMap::new(),
            client_senders: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Get a clone of the client-sender registry so the server can register
    /// new clients without borrowing the whole PtyManager.
    pub fn client_sender_registry(
        &self,
    ) -> Arc<Mutex<HashMap<String, mpsc::UnboundedSender<ServerMsg>>>> {
        Arc::clone(&self.client_senders)
    }

    // ── spawn ─────────────────────────────────────────────────────────────────

    /// Spawn a new PTY process.  Returns the canonical `pty_id`.
    pub fn spawn_pty(
        &mut self,
        pty_id: String,
        cmd: &str,
        args: &[String],
        cols: u16,
        rows: u16,
        cwd: Option<PathBuf>,
        client_tag: String,
    ) -> Result<String> {
        let pty_system = portable_pty::native_pty_system();
        let pair = pty_system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let mut cmd_builder = CommandBuilder::new(cmd);
        for arg in args {
            cmd_builder.arg(arg);
        }
        if let Some(dir) = cwd.or_else(|| std::env::current_dir().ok()) {
            cmd_builder.cwd(dir);
        }

        let child = pair.slave.spawn_command(cmd_builder)?;
        drop(pair.slave);

        let mut reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;

        let (output_tx, _) = broadcast::channel::<PtyChunk>(256);
        let scrollback = Arc::new(Mutex::new(ScrollbackBuf::new()));

        let output_tx_clone = output_tx.clone();
        let scrollback_clone = Arc::clone(&scrollback);
        let pty_id_for_task = pty_id.clone();

        let reader_task = tokio::task::spawn_blocking(move || {
            use std::io::Read;
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => {
                        debug!(pty_id = %pty_id_for_task, "PTY reader EOF");
                        let _ = output_tx_clone.send(PtyChunk::Exited { exit_code: None });
                        break;
                    }
                    Ok(n) => {
                        let chunk = buf[..n].to_vec();
                        scrollback_clone.lock().unwrap().push(chunk.clone());
                        // Ignore send errors — no subscribers yet is fine.
                        let _ = output_tx_clone.send(PtyChunk::Bytes(chunk));
                    }
                    Err(e) => {
                        use std::io::ErrorKind;
                        if !matches!(
                            e.kind(),
                            ErrorKind::WouldBlock
                                | ErrorKind::Interrupted
                                | ErrorKind::ConnectionReset
                        ) {
                            warn!(pty_id = %pty_id_for_task, "PTY read error: {e}");
                        }
                        let _ = output_tx_clone.send(PtyChunk::Exited { exit_code: None });
                        break;
                    }
                }
            }
        });

        self.ptys.insert(
            pty_id.clone(),
            ManagedPty {
                writer,
                child,
                scrollback,
                output_tx,
                alive: true,
                cols,
                rows,
                master: pair.master,
                cmd: cmd.to_string(),
                args: args.to_vec(),
                last_activity: SystemTime::now(),
                client_tag,
                attached_client: None,
                forwarder_handle: None,
                _reader_task: reader_task,
            },
        );

        info!(pty_id, "PTY spawned");
        Ok(pty_id)
    }

    // ── attach ────────────────────────────────────────────────────────────────

    /// Attach `client_id` to `pty_id`.
    ///
    /// Sends `PtyAttached` + `PtyScrollback` to the client, then starts
    /// forwarding live output.  If another client was attached, it first
    /// receives `PtyDetach`.
    pub fn attach(
        &mut self,
        pty_id: &str,
        client_id: &str,
    ) -> Result<()> {
        // ── Phase 1: mutate PTY state, collect what we need ───────────────────
        let (old_client, cols, rows, scrollback_bytes, output_rx) = {
            let pty = self
                .ptys
                .get_mut(pty_id)
                .ok_or_else(|| anyhow::anyhow!("unknown pty_id: {pty_id}"))?;

            let old_client = pty.attached_client.take();

            if let Some(handle) = pty.forwarder_handle.take() {
                handle.abort();
            }

            pty.attached_client = Some(client_id.to_string());

            let cols = pty.cols;
            let rows = pty.rows;
            let scrollback_bytes = pty.scrollback.lock().unwrap().drain();
            let output_rx = pty.output_tx.subscribe();

            (old_client, cols, rows, scrollback_bytes, output_rx)
        };

        // ── Phase 2: send control messages (no mutable ptys borrow) ──────────

        if let Some(ref old) = old_client {
            if old != client_id {
                self.send_to_client(
                    old,
                    ServerMsg::PtyDetach {
                        pty_id: pty_id.to_string(),
                    },
                );
            }
        }

        self.send_to_client(
            client_id,
            ServerMsg::PtyAttached {
                pty_id: pty_id.to_string(),
                cols,
                rows,
            },
        );

        if !scrollback_bytes.is_empty() {
            self.send_to_client(
                client_id,
                ServerMsg::PtyScrollback {
                    pty_id: pty_id.to_string(),
                    bytes: scrollback_bytes,
                },
            );
        }

        // ── Phase 3: spawn forwarder task ─────────────────────────────────────

        let mut rx = output_rx;
        let pty_id_str = pty_id.to_string();
        let client_id_str = client_id.to_string();
        let senders = Arc::clone(&self.client_senders);

        let task = tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(PtyChunk::Bytes(bytes)) => {
                        let senders = senders.lock().unwrap();
                        if let Some(tx) = senders.get(&client_id_str) {
                            let _ = tx.send(ServerMsg::PtyOutput {
                                pty_id: pty_id_str.clone(),
                                bytes,
                            });
                        } else {
                            break; // client disconnected
                        }
                    }
                    Ok(PtyChunk::Exited { exit_code }) => {
                        let senders = senders.lock().unwrap();
                        if let Some(tx) = senders.get(&client_id_str) {
                            let _ = tx.send(ServerMsg::PtyExited {
                                pty_id: pty_id_str.clone(),
                                exit_code,
                            });
                        }
                        break;
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!(
                            pty_id = %pty_id_str,
                            client_id = %client_id_str,
                            "forwarder lagged {n} chunks"
                        );
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });

        // ── Phase 4: store abort handle ───────────────────────────────────────
        let pty = self.ptys.get_mut(pty_id).unwrap();
        pty.forwarder_handle = Some(task.abort_handle());

        info!(pty_id, client_id, "PTY attach");
        Ok(())
    }

    // ── detach ────────────────────────────────────────────────────────────────

    /// Detach `client_id` from `pty_id` (PTY keeps running).
    pub fn detach(&mut self, pty_id: &str, client_id: &str) {
        if let Some(pty) = self.ptys.get_mut(pty_id) {
            if pty.attached_client.as_deref() == Some(client_id) {
                pty.attached_client = None;
                if let Some(handle) = pty.forwarder_handle.take() {
                    handle.abort();
                }
                debug!(pty_id, client_id, "PTY detached");
            }
        }
    }

    // ── input / resize / kill ─────────────────────────────────────────────────

    /// Write `bytes` to the PTY's stdin.
    pub fn send_input(&mut self, pty_id: &str, bytes: &[u8]) -> Result<()> {
        let pty = self
            .ptys
            .get_mut(pty_id)
            .ok_or_else(|| anyhow::anyhow!("unknown pty_id: {pty_id}"))?;

        if !pty.alive {
            anyhow::bail!("PTY {pty_id} is no longer alive");
        }

        use std::io::Write;
        pty.writer.write_all(bytes)?;
        pty.last_activity = SystemTime::now();
        Ok(())
    }

    /// Resize PTY to `(cols, rows)`.
    pub fn resize_pty(&mut self, pty_id: &str, cols: u16, rows: u16) -> Result<()> {
        let pty = self
            .ptys
            .get_mut(pty_id)
            .ok_or_else(|| anyhow::anyhow!("unknown pty_id: {pty_id}"))?;

        pty.cols = cols;
        pty.rows = rows;
        pty.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        Ok(())
    }

    /// Kill the child process for `pty_id` and mark it dead.
    pub fn kill_pty(&mut self, pty_id: &str) {
        if let Some(pty) = self.ptys.get_mut(pty_id) {
            pty.child.kill().ok();
            pty.alive = false;
            if let Some(h) = pty.forwarder_handle.take() {
                h.abort();
            }
            debug!(pty_id, "PTY killed");
        }
    }

    // ── list ──────────────────────────────────────────────────────────────────

    /// Return a snapshot of all PTYs.
    pub fn list(&self) -> Vec<PtyInfo> {
        self.ptys
            .values()
            .map(|p| PtyInfo {
                pty_id: self
                    .ptys
                    .iter()
                    .find_map(|(k, v)| {
                        if std::ptr::eq(v, p) { Some(k.clone()) } else { None }
                    })
                    .unwrap_or_default(),
                cmd: p.cmd.clone(),
                args: p.args.clone(),
                alive: p.alive,
                cols: p.cols,
                rows: p.rows,
                last_activity: Some(p.last_activity),
                client_tag: p.client_tag.clone(),
            })
            .collect()
    }

    /// Return a snapshot of all PTYs (with correct ids).
    pub fn list_with_ids(&self) -> Vec<PtyInfo> {
        self.ptys
            .iter()
            .map(|(id, p)| PtyInfo {
                pty_id: id.clone(),
                cmd: p.cmd.clone(),
                args: p.args.clone(),
                alive: p.alive,
                cols: p.cols,
                rows: p.rows,
                last_activity: Some(p.last_activity),
                client_tag: p.client_tag.clone(),
            })
            .collect()
    }

    // ── shutdown ──────────────────────────────────────────────────────────────

    /// Kill all child processes.  Called on SIGTERM.
    pub fn kill_all_on_shutdown(&mut self) {
        for (id, pty) in &mut self.ptys {
            if pty.alive {
                pty.child.kill().ok();
                info!(pty_id = %id, "PTY killed on shutdown");
            }
            if let Some(h) = pty.forwarder_handle.take() {
                h.abort();
            }
        }
        self.ptys.clear();
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    fn send_to_client(&self, client_id: &str, msg: ServerMsg) {
        let senders = self.client_senders.lock().unwrap();
        if let Some(tx) = senders.get(client_id) {
            let _ = tx.send(msg);
        }
    }

    /// Called when a client handler exits to detach all their PTYs.
    pub fn on_client_disconnect(&mut self, client_id: &str) {
        let pty_ids: Vec<String> = self
            .ptys
            .iter()
            .filter_map(|(id, p)| {
                if p.attached_client.as_deref() == Some(client_id) {
                    Some(id.clone())
                } else {
                    None
                }
            })
            .collect();

        for pty_id in pty_ids {
            self.detach(&pty_id, client_id);
        }

        let mut senders = self.client_senders.lock().unwrap();
        senders.remove(client_id);
    }
}

impl Default for PtyManager {
    fn default() -> Self {
        Self::new()
    }
}
