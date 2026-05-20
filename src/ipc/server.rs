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
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc};
use tracing::{debug, info, warn};

use super::{
    codec::{read_frame, write_frame},
    protocol::{ClientMsg, ServerMsg, Topic, MIN_CLIENT_VERSION, PROTOCOL_VERSION},
    pty_manager::PtyManager,
};

/// Handle to the running IPC server.  Drop to shut down.
pub struct Server {
    socket_path: PathBuf,
    pub tx: broadcast::Sender<ServerMsg>,
}

impl Server {
    /// Bind a `UnixListener` at `socket_path`.
    ///
    /// `pty_mgr` is shared with every client handler for PTY command routing.
    pub fn bind(socket_path: &Path, pty_mgr: Arc<Mutex<PtyManager>>) -> Result<Self> {
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
            if let Err(e) = accept_loop(listener, tx_clone, pty_mgr).await {
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
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

// ── accept loop ───────────────────────────────────────────────────────────────

async fn accept_loop(
    listener: UnixListener,
    tx: broadcast::Sender<ServerMsg>,
    pty_mgr: Arc<Mutex<PtyManager>>,
) -> Result<()> {
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let rx = tx.subscribe();
                let pty_mgr = Arc::clone(&pty_mgr);
                tokio::spawn(async move {
                    if let Err(e) = handle_client(stream, rx, pty_mgr).await {
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

// ── per-client task ───────────────────────────────────────────────────────────

async fn handle_client(
    stream: UnixStream,
    mut broadcast_rx: broadcast::Receiver<ServerMsg>,
    pty_mgr: Arc<Mutex<PtyManager>>,
) -> Result<()> {
    let (mut reader, mut writer) = tokio::io::split(stream);

    // ── Handshake ─────────────────────────────────────────────────────────────

    let hello_bytes = read_frame(&mut reader).await?;
    let hello: ClientMsg = serde_json::from_slice(&hello_bytes)?;

    let client_id = match hello {
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
            client_id.clone()
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
    debug!(client_id, "client welcomed");

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

    info!(client_id, ?topics, "client subscribed");

    // ── Register per-client targeted channel ──────────────────────────────────

    let (targeted_tx, mut targeted_rx) = mpsc::unbounded_channel::<ServerMsg>();
    {
        let mgr = pty_mgr.lock().unwrap();
        let registry = mgr.client_sender_registry();
        let mut senders = registry.lock().unwrap();
        senders.insert(client_id.clone(), targeted_tx.clone());
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
                        warn!(client_id, "client lagged {n} broadcast messages");
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
                                warn!(client_id, "bad ClientMsg: {e}");
                                continue;
                            }
                        };
                        handle_client_msg(msg, &client_id, &pty_mgr, &targeted_tx);
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

    debug!(client_id, "client handler exiting; detaching PTYs");
    {
        let mut mgr = pty_mgr.lock().unwrap();
        mgr.on_client_disconnect(&client_id);
    }

    result
}

// ── PTY command dispatch ──────────────────────────────────────────────────────

fn handle_client_msg(
    msg: ClientMsg,
    client_id: &str,
    pty_mgr: &Arc<Mutex<PtyManager>>,
    targeted_tx: &mpsc::UnboundedSender<ServerMsg>,
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
                    warn!(client_id, cmd, "PtySpawn failed: {e:#}");
                    let _ = targeted_tx.send(ServerMsg::Error {
                        message: format!("PtySpawn failed: {e}"),
                    });
                }
            }
        }

        ClientMsg::PtyAttach { pty_id } => {
            let result = {
                let mut mgr = pty_mgr.lock().unwrap();
                mgr.attach(&pty_id, client_id)
            };
            if let Err(e) = result {
                let _ = targeted_tx.send(ServerMsg::Error {
                    message: format!("PtyAttach failed: {e}"),
                });
            }
        }

        ClientMsg::PtyDetach { pty_id } => {
            let mut mgr = pty_mgr.lock().unwrap();
            mgr.detach(&pty_id, client_id);
        }

        ClientMsg::PtyInput { pty_id, bytes } => {
            let mut mgr = pty_mgr.lock().unwrap();
            if let Err(e) = mgr.send_input(&pty_id, &bytes) {
                warn!(client_id, "PtyInput error: {e}");
            }
        }

        ClientMsg::PtyResize { pty_id, cols, rows } => {
            let mut mgr = pty_mgr.lock().unwrap();
            if let Err(e) = mgr.resize_pty(&pty_id, cols, rows) {
                warn!(client_id, "PtyResize error: {e}");
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
        // PTY + control messages are always forwarded (handled via targeted channel).
        _ => true,
    }
}
