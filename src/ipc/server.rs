//! Daemon-side IPC server.
//!
//! Accepts Unix socket connections, performs the `Hello`/`Welcome` handshake,
//! then fans out broadcast `ServerMsg`s to all subscribed clients.

use std::path::{Path, PathBuf};

use anyhow::Result;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::broadcast;
use tracing::{debug, info, warn};

use super::{
    codec::{read_frame, write_frame},
    protocol::{ClientMsg, PROTOCOL_VERSION, ServerMsg, Topic},
};

/// Handle to the running IPC server.  Drop to shut down.
pub struct Server {
    socket_path: PathBuf,
    pub tx: broadcast::Sender<ServerMsg>,
}

impl Server {
    /// Bind a `UnixListener` at `socket_path`.
    ///
    /// Removes any stale socket file first.  Sets file mode to `0o600`.
    pub fn bind(socket_path: &Path) -> Result<Self> {
        // Remove stale socket file so bind doesn't fail.
        let _ = std::fs::remove_file(socket_path);

        // Ensure parent directory exists.
        if let Some(parent) = socket_path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let listener = UnixListener::bind(socket_path)?;

        // Restrict access to owner only.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600))?;
        }

        let (tx, _) = broadcast::channel::<ServerMsg>(512);
        let tx_clone = tx.clone();
        let path = socket_path.to_path_buf();

        tokio::spawn(async move {
            if let Err(e) = accept_loop(listener, tx_clone).await {
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
        // Ignore send errors — they just mean no clients are connected.
        let _ = self.tx.send(msg);
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

// ── accept loop ───────────────────────────────────────────────────────────────

async fn accept_loop(listener: UnixListener, tx: broadcast::Sender<ServerMsg>) -> Result<()> {
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let rx = tx.subscribe();
                tokio::spawn(async move {
                    if let Err(e) = handle_client(stream, rx).await {
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
    mut rx: broadcast::Receiver<ServerMsg>,
) -> Result<()> {
    let (mut reader, mut writer) = tokio::io::split(stream);

    // ── Handshake ─────────────────────────────────────────────────────────────

    let hello_bytes = read_frame(&mut reader).await?;
    let hello: ClientMsg = serde_json::from_slice(&hello_bytes)?;

    let client_id = match hello {
        ClientMsg::Hello { ref client_id, .. } => client_id.clone(),
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

    // ── Fan-out loop ──────────────────────────────────────────────────────────

    loop {
        match rx.recv().await {
            Ok(msg) => {
                if !message_matches_topics(&msg, &topics) {
                    continue;
                }
                let bytes = serde_json::to_vec(&msg)?;
                if write_frame(&mut writer, &bytes).await.is_err() {
                    break; // client disconnected
                }
            }
            Err(broadcast::error::RecvError::Lagged(n)) => {
                warn!(client_id, "client lagged {n} messages, continuing");
            }
            Err(broadcast::error::RecvError::Closed) => {
                break; // server is shutting down
            }
        }
    }

    debug!(client_id, "client handler exiting");
    Ok(())
}

fn message_matches_topics(msg: &ServerMsg, topics: &[Topic]) -> bool {
    if topics.is_empty() {
        return true; // subscribed to everything (or no Subscribe was sent)
    }
    match msg {
        ServerMsg::Activity(_) => topics.contains(&Topic::Activity),
        ServerMsg::MotherJobs(_) => topics.contains(&Topic::MotherJobs),
        ServerMsg::MotherStatusline(_) => topics.contains(&Topic::MotherStatusline),
        ServerMsg::MotherAwaitDetected(_) => topics.contains(&Topic::MotherJobs),
        ServerMsg::Pong | ServerMsg::Welcome { .. } | ServerMsg::Error { .. } => true,
    }
}
