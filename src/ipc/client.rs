//! TUI-side IPC client.
//!
//! Connects to the daemon over a Unix socket, performs the `Hello`/`Welcome`
//! handshake, subscribes to all topics, then returns an `mpsc::Receiver` that
//! delivers `ServerMsg`s to the caller.
//!
//! **No auto-reconnect in Phase 5a.**  If the daemon dies mid-session the
//! receiver simply goes quiet; callers must fall back to in-process mode.

use std::path::Path;

use anyhow::{bail, Context, Result};
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use super::{
    codec::{read_frame, write_frame},
    protocol::{ClientMsg, PROTOCOL_VERSION, ServerMsg, Topic},
};

/// Connected daemon client.
pub struct DaemonClient {
    /// Incoming server messages.
    pub rx: mpsc::Receiver<ServerMsg>,
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
                info!(
                    daemon_pid,
                    protocol_version, "connected to nostromd"
                );
                if protocol_version != PROTOCOL_VERSION {
                    warn!(
                        "protocol version mismatch: daemon={protocol_version} client={PROTOCOL_VERSION}"
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

        // ── Reader task ───────────────────────────────────────────────────────

        let (tx, rx) = mpsc::channel::<ServerMsg>(256);

        tokio::spawn(async move {
            loop {
                match read_frame(&mut reader).await {
                    Ok(bytes) => match serde_json::from_slice::<ServerMsg>(&bytes) {
                        Ok(msg) => {
                            if tx.send(msg).await.is_err() {
                                break; // receiver dropped
                            }
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

        Ok(Self { rx })
    }
}
