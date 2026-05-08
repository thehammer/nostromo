//! TUI-side IPC client.
//!
//! Connects to the daemon over a Unix socket, performs the `Hello`/`Welcome`
//! handshake, subscribes to all topics, then exposes:
//!
//! - [`DaemonClient::subscribe`] — get a [`broadcast::Receiver`] for all
//!   incoming [`ServerMsg`]s.  Multiple subscribers are supported; use this
//!   for PTY consumers and the daemon bridge alike.
//! - [`DaemonClient::send`] — send a [`ClientMsg`] to the daemon asynchronously.
//! - [`DaemonClient`] is `Clone` so it can be shared between the bridge task
//!   and `DaemonPtyFactory`.
//!
//! **No auto-reconnect.**  If the daemon dies mid-session the broadcast
//! channel closes; callers must fall back to in-process mode.

use std::path::Path;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, mpsc};
use tracing::{debug, info, warn};

use super::{
    codec::{read_frame, write_frame},
    protocol::{ClientMsg, MIN_CLIENT_VERSION, PROTOCOL_VERSION, ServerMsg, Topic},
};

// ── inner ─────────────────────────────────────────────────────────────────────

struct DaemonClientInner {
    /// Channel for sending messages to the daemon.
    write_tx: mpsc::UnboundedSender<ClientMsg>,
    /// Broadcast of every incoming `ServerMsg`.
    all_msgs_tx: broadcast::Sender<ServerMsg>,
}

// ── public handle ─────────────────────────────────────────────────────────────

/// Connected daemon client.  Cheap to clone — shares the underlying connection.
#[derive(Clone)]
pub struct DaemonClient {
    inner: Arc<DaemonClientInner>,
}

impl DaemonClient {
    /// Connect to the daemon socket at `path`, perform the handshake, subscribe
    /// to all three topics, and return a live `DaemonClient`.
    ///
    /// Fails immediately if the socket is not present or the handshake fails.
    pub async fn connect(path: &Path) -> Result<Self> {
        let stream = UnixStream::connect(path)
            .await
            .with_context(|| format!("connecting to {}", path.display()))?;

        let (mut reader, mut writer) = tokio::io::split(stream);

        // ── Hello ─────────────────────────────────────────────────────────────

        let client_id = format!(
            "{}-{}",
            std::env::var("HOSTNAME").unwrap_or_else(|_| "nostromo".into()),
            std::process::id()
        );

        let hello = ClientMsg::Hello {
            client_id: client_id.clone(),
            protocol_version: PROTOCOL_VERSION,
        };
        write_frame(&mut writer, &serde_json::to_vec(&hello)?).await?;

        // ── Welcome ───────────────────────────────────────────────────────────

        let welcome_bytes = read_frame(&mut reader).await?;
        let welcome: ServerMsg = serde_json::from_slice(&welcome_bytes)?;
        match welcome {
            ServerMsg::Welcome {
                protocol_version,
                daemon_pid,
            } => {
                info!(daemon_pid, protocol_version, "connected to nostromd");
                if protocol_version < MIN_CLIENT_VERSION {
                    bail!(
                        "daemon protocol version {protocol_version} is too old (need \
                         {MIN_CLIENT_VERSION}+)"
                    );
                }
            }
            ServerMsg::Error { message } => bail!("daemon rejected hello: {message}"),
            other => bail!("unexpected welcome message: {other:?}"),
        }

        // ── Subscribe ─────────────────────────────────────────────────────────

        let subscribe = ClientMsg::Subscribe {
            topics: vec![Topic::Activity, Topic::MotherJobs, Topic::MotherStatusline],
        };
        write_frame(&mut writer, &serde_json::to_vec(&subscribe)?).await?;
        debug!(client_id, "sent Subscribe");

        // ── Channels ──────────────────────────────────────────────────────────

        let (all_msgs_tx, _) = broadcast::channel::<ServerMsg>(512);
        let (write_tx, mut write_rx) = mpsc::unbounded_channel::<ClientMsg>();

        // Writer task: drain write_rx → socket.
        let all_msgs_tx_clone = all_msgs_tx.clone();
        tokio::spawn(async move {
            while let Some(msg) = write_rx.recv().await {
                match serde_json::to_vec(&msg) {
                    Ok(bytes) => {
                        if write_frame(&mut writer, &bytes).await.is_err() {
                            break; // socket closed
                        }
                    }
                    Err(e) => {
                        warn!("failed to serialise ClientMsg: {e}");
                    }
                }
            }
            // Signal all subscribers that the connection is gone.
            drop(all_msgs_tx_clone);
        });

        // Reader task: socket → broadcast.
        let all_msgs_tx_reader = all_msgs_tx.clone();
        tokio::spawn(async move {
            loop {
                match read_frame(&mut reader).await {
                    Ok(bytes) => match serde_json::from_slice::<ServerMsg>(&bytes) {
                        Ok(msg) => {
                            // Ignore send errors — no subscribers is fine.
                            let _ = all_msgs_tx_reader.send(msg);
                        }
                        Err(e) => {
                            warn!("failed to deserialise server message: {e}");
                        }
                    },
                    Err(e) => {
                        debug!("daemon reader task exiting: {e:#}");
                        break;
                    }
                }
            }
            debug!("daemon reader task done");
        });

        Ok(Self {
            inner: Arc::new(DaemonClientInner {
                write_tx,
                all_msgs_tx,
            }),
        })
    }

    // ── public API ────────────────────────────────────────────────────────────

    /// Subscribe to all incoming [`ServerMsg`]s.
    ///
    /// Messages sent before this call are NOT replayed.  Each subscriber
    /// receives every message independently.
    pub fn subscribe(&self) -> broadcast::Receiver<ServerMsg> {
        self.inner.all_msgs_tx.subscribe()
    }

    /// Send a [`ClientMsg`] to the daemon.  Returns an error only if the
    /// write task has already exited (daemon connection lost).
    pub fn send(&self, msg: ClientMsg) -> Result<()> {
        self.inner
            .write_tx
            .send(msg)
            .map_err(|_| anyhow::anyhow!("daemon write channel closed"))
    }
}
