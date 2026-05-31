//! TUI-side IPC client with auto-reconnect.
//!
//! Connects to the daemon over a Unix socket, performs the `Hello`/`Welcome`
//! handshake, subscribes to all topics, and then exposes:
//!
//! - [`DaemonClient::subscribe`] — get a [`broadcast::Receiver`] for all
//!   incoming [`ServerMsg`]s.  Multiple subscribers are supported; use this
//!   for PTY consumers and the daemon bridge alike.
//! - [`DaemonClient::send`] — send a [`ClientMsg`] to the daemon asynchronously.
//! - [`DaemonClient::connection_state`] — watch the current connection state.
//! - [`DaemonClient`] is `Clone` so it can be shared between the bridge task
//!   and `DaemonPtyFactory`.
//!
//! **Auto-reconnect.**  A supervisor task monitors the socket.  When the
//! connection drops it loops with exponential backoff (1 s → 30 s capped),
//! re-establishes the socket, re-runs the handshake, and emits a synthetic
//! [`ServerMsg::DaemonReconnected`] so subscribers can resync (e.g.
//! `DaemonPtyClient` re-issues `PtyAttach`).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use tokio::io::{ReadHalf, WriteHalf};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, mpsc, watch};
use tracing::{debug, info, warn};

use super::{
    codec::{read_frame, write_frame},
    protocol::{ClientMsg, ServerMsg, Topic, MIN_CLIENT_VERSION, PROTOCOL_VERSION},
};

// ── ConnectionState ───────────────────────────────────────────────────────────

/// Current state of the daemon socket connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionState {
    /// Performing the initial connection or handshake.
    Connecting,
    /// Successfully connected to the daemon.
    Connected {
        /// PID of the daemon process.
        daemon_pid: u32,
    },
    /// Waiting before the next reconnect attempt.
    Reconnecting {
        /// Number of reconnect attempts made so far.
        attempt: u32,
        /// Seconds until the next attempt.
        backoff_secs: u32,
    },
}

// ── inner ─────────────────────────────────────────────────────────────────────

struct DaemonClientInner {
    /// Channel for queuing outbound messages.  The supervisor drains this into
    /// each successive socket generation.
    write_tx: mpsc::UnboundedSender<ClientMsg>,
    /// Broadcast of every incoming `ServerMsg`.  Never rebuilt across
    /// reconnects — all `Receiver`s remain valid.
    all_msgs_tx: broadcast::Sender<ServerMsg>,
    /// Current connection state.
    state_tx: watch::Sender<ConnectionState>,
}

// ── public handle ─────────────────────────────────────────────────────────────

/// Connected daemon client with transparent auto-reconnect.
///
/// Cheap to clone — all clones share the same underlying supervisor.
#[derive(Clone)]
pub struct DaemonClient {
    inner: Arc<DaemonClientInner>,
}

impl DaemonClient {
    /// Connect to the daemon socket at `path`, perform the handshake, and
    /// return a live `DaemonClient`.
    ///
    /// Fails immediately if the socket is not present or the handshake fails.
    /// A background supervisor task will reconnect automatically if the daemon
    /// restarts later.
    pub async fn connect(path: &Path) -> Result<Self> {
        Self::connect_with_backoff(path, Duration::from_secs(1), Duration::from_secs(30)).await
    }

    /// Like [`connect`] but with configurable backoff parameters.
    ///
    /// `initial_backoff` is the first retry interval; each successive attempt
    /// doubles it up to `max_backoff`.  Used in tests to speed up reconnect
    /// cycles without touching production defaults.
    pub(crate) async fn connect_with_backoff(
        path: &Path,
        initial_backoff: Duration,
        max_backoff: Duration,
    ) -> Result<Self> {
        // First connection is synchronous — fail fast if the daemon is not up.
        let (reader, writer, daemon_pid) = do_connect(path).await?;

        // Stable channels: created once, survive across reconnect generations.
        let (all_msgs_tx, _) = broadcast::channel::<ServerMsg>(512);
        let (write_tx, write_rx) = mpsc::unbounded_channel::<ClientMsg>();
        let (state_tx, _) = watch::channel(ConnectionState::Connected { daemon_pid });

        let inner = Arc::new(DaemonClientInner {
            write_tx,
            all_msgs_tx: all_msgs_tx.clone(),
            state_tx: state_tx.clone(),
        });

        tokio::spawn(supervisor_task(
            reader,
            writer,
            write_rx,
            all_msgs_tx,
            state_tx,
            ReconnectConfig {
                socket_path: path.to_path_buf(),
                initial_backoff,
                max_backoff,
            },
        ));

        Ok(Self { inner })
    }

    // ── public API ────────────────────────────────────────────────────────────

    /// Subscribe to all incoming [`ServerMsg`]s.
    ///
    /// Messages sent before this call are NOT replayed.  Each subscriber
    /// receives every message independently.
    ///
    /// The returned [`broadcast::Receiver`] remains valid across daemon
    /// reconnects — the underlying channel is never rebuilt.
    pub fn subscribe(&self) -> broadcast::Receiver<ServerMsg> {
        self.inner.all_msgs_tx.subscribe()
    }

    /// Send a [`ClientMsg`] to the daemon.
    ///
    /// If the socket is currently disconnected the message is queued and
    /// delivered once the supervisor re-establishes the connection.  Returns an
    /// error only if the supervisor has exited (i.e. every `DaemonClient` clone
    /// was dropped).
    pub fn send(&self, msg: ClientMsg) -> Result<()> {
        self.inner
            .write_tx
            .send(msg)
            .map_err(|_| anyhow::anyhow!("daemon write channel closed"))
    }

    /// Watch the current connection state.
    ///
    /// Returns a [`watch::Receiver`] that is updated whenever the supervisor
    /// transitions between [`ConnectionState`] variants.
    pub fn connection_state(&self) -> watch::Receiver<ConnectionState> {
        self.inner.state_tx.subscribe()
    }
}

// ── supervisor config ─────────────────────────────────────────────────────────

struct ReconnectConfig {
    socket_path: PathBuf,
    initial_backoff: Duration,
    max_backoff: Duration,
}

// ── low-level connection helpers ──────────────────────────────────────────────

type SplitReader = ReadHalf<UnixStream>;
type SplitWriter = WriteHalf<UnixStream>;

/// Open the socket and perform `Hello` / `Welcome` / `Subscribe`.
///
/// Returns `(reader, writer, daemon_pid)` on success.
async fn do_connect(path: &Path) -> Result<(SplitReader, SplitWriter, u32)> {
    let stream = UnixStream::connect(path)
        .await
        .with_context(|| format!("connecting to {}", path.display()))?;

    let (mut reader, mut writer) = tokio::io::split(stream);

    // ── Hello ─────────────────────────────────────────────────────────────────

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

    // ── Welcome ───────────────────────────────────────────────────────────────

    let welcome_bytes = read_frame(&mut reader).await?;
    let welcome: ServerMsg = serde_json::from_slice(&welcome_bytes)?;
    let daemon_pid = match welcome {
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
            daemon_pid
        }
        ServerMsg::Error { message } => bail!("daemon rejected hello: {message}"),
        other => bail!("unexpected welcome message: {other:?}"),
    };

    // ── Subscribe ─────────────────────────────────────────────────────────────

    let subscribe = ClientMsg::Subscribe {
        topics: vec![Topic::Activity, Topic::MotherJobs, Topic::MotherStatusline],
    };
    write_frame(&mut writer, &serde_json::to_vec(&subscribe)?).await?;
    debug!(client_id, "sent Subscribe");

    Ok((reader, writer, daemon_pid))
}

/// Exponential backoff: `initial * 2^(attempt − 1)`, capped at `max`.
///
/// attempt=1 → initial, attempt=2 → 2×initial, attempt=3 → 4×initial, …
fn backoff_duration(attempt: u32, initial: Duration, max: Duration) -> Duration {
    let factor = 2u64.saturating_pow(attempt.saturating_sub(1));
    let nanos = (initial.as_nanos() as u64)
        .saturating_mul(factor)
        .min(max.as_nanos() as u64);
    Duration::from_nanos(nanos)
}

// ── supervisor task ───────────────────────────────────────────────────────────

/// Manages the socket connection across reconnect generations.
///
/// Starts with the already-connected `initial_reader`/`initial_writer`; on
/// I/O error it sleeps with backoff and re-establishes the connection.  Exits
/// cleanly when the last `DaemonClient` clone is dropped (detected via a
/// closed `write_rx`).
async fn supervisor_task(
    initial_reader: SplitReader,
    initial_writer: SplitWriter,
    mut write_rx: mpsc::UnboundedReceiver<ClientMsg>,
    all_msgs_tx: broadcast::Sender<ServerMsg>,
    state_tx: watch::Sender<ConnectionState>,
    cfg: ReconnectConfig,
) {
    // Run the first generation (socket already open from `connect()`).
    let shutdown =
        run_generation(initial_reader, initial_writer, &mut write_rx, &all_msgs_tx).await;
    if shutdown {
        return;
    }

    // Reconnect loop.
    let mut attempt: u32 = 0;
    loop {
        attempt += 1;
        let backoff = backoff_duration(attempt, cfg.initial_backoff, cfg.max_backoff);
        let _ = state_tx.send(ConnectionState::Reconnecting {
            attempt,
            backoff_secs: backoff.as_secs() as u32,
        });
        debug!(
            attempt,
            backoff_ms = backoff.as_millis(),
            "will reconnect to nostromd"
        );

        tokio::time::sleep(backoff).await;

        let _ = state_tx.send(ConnectionState::Connecting);

        match tokio::time::timeout(Duration::from_secs(5), do_connect(&cfg.socket_path)).await {
            Ok(Ok((reader, writer, daemon_pid))) => {
                info!(daemon_pid, attempt, "reconnected to nostromd");
                let _ = state_tx.send(ConnectionState::Connected { daemon_pid });
                // Synthetic event so subscribers can re-issue attach/subscribe.
                let _ = all_msgs_tx.send(ServerMsg::DaemonReconnected);

                attempt = 0;
                let shutdown = run_generation(reader, writer, &mut write_rx, &all_msgs_tx).await;
                if shutdown {
                    return;
                }
            }
            Ok(Err(e)) => {
                debug!("reconnect attempt {attempt} failed: {e:#}");
            }
            Err(_) => {
                debug!("reconnect attempt {attempt} timed out after 5 s");
            }
        }
    }
}

/// Run one connection generation: pump `write_rx` → socket and socket → broadcast.
///
/// Returns `true` if `write_rx` was closed (all `DaemonClient` clones dropped)
/// and the supervisor should exit cleanly, or `false` if the socket failed and
/// the caller should attempt a reconnect.
async fn run_generation(
    mut reader: SplitReader,
    mut writer: SplitWriter,
    write_rx: &mut mpsc::UnboundedReceiver<ClientMsg>,
    all_msgs_tx: &broadcast::Sender<ServerMsg>,
) -> bool {
    loop {
        tokio::select! {
            // Outbound: drain the write queue into the socket.
            msg = write_rx.recv() => {
                match msg {
                    None => {
                        // All DaemonClient clones were dropped — shut down.
                        return true;
                    }
                    Some(msg) => {
                        match serde_json::to_vec(&msg) {
                            Ok(bytes) => {
                                if write_frame(&mut writer, &bytes).await.is_err() {
                                    // Socket write failed — reconnect.
                                    return false;
                                }
                            }
                            Err(e) => {
                                warn!("failed to serialise ClientMsg: {e}");
                            }
                        }
                    }
                }
            }

            // Inbound: broadcast received frames to all subscribers.
            frame = read_frame(&mut reader) => {
                match frame {
                    Ok(bytes) => {
                        match serde_json::from_slice::<ServerMsg>(&bytes) {
                            Ok(msg) => {
                                // Ignore send errors — no subscribers is fine.
                                let _ = all_msgs_tx.send(msg);
                            }
                            Err(e) => {
                                warn!("failed to deserialise server message: {e}");
                            }
                        }
                    }
                    Err(e) => {
                        debug!("socket read failed: {e:#}; will reconnect");
                        return false;
                    }
                }
            }
        }
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::net::UnixListener;

    use super::*;
    use crate::ipc::codec::{read_frame, write_frame};

    /// Perform the daemon side of the handshake on a connected stream.
    async fn serve_handshake(stream: tokio::net::UnixStream, daemon_pid: u32) {
        let (mut reader, mut writer) = tokio::io::split(stream);

        // Read Hello
        let bytes = read_frame(&mut reader).await.expect("read Hello");
        let _: ClientMsg = serde_json::from_slice(&bytes).expect("parse Hello");

        // Write Welcome
        let welcome = ServerMsg::Welcome {
            protocol_version: PROTOCOL_VERSION,
            daemon_pid,
        };
        write_frame(&mut writer, &serde_json::to_vec(&welcome).unwrap())
            .await
            .expect("write Welcome");

        // Read Subscribe
        let _bytes = read_frame(&mut reader).await.expect("read Subscribe");
    }

    /// Verify that `DaemonClient` reconnects after a socket drop, transitions
    /// through `Reconnecting` → `Connected`, and emits `DaemonReconnected`.
    #[tokio::test]
    async fn reconnect_roundtrips_send_and_receive() {
        let sock_path = std::env::temp_dir().join(format!(
            "nostromo_reconnect_test_{}.sock",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&sock_path);

        let listener = UnixListener::bind(&sock_path).unwrap();

        // Oneshot: gen 1 signals when its handshake is done (and stream will drop).
        let (gen1_done_tx, gen1_done_rx) = tokio::sync::oneshot::channel::<()>();

        let fake_daemon = tokio::spawn(async move {
            // Generation 1: complete handshake then drop the stream.
            {
                let (stream1, _) = listener.accept().await.unwrap();
                serve_handshake(stream1, 1234).await;
                // stream1 drops here → socket closed → client should reconnect.
            }
            let _ = gen1_done_tx.send(());

            // Generation 2: complete handshake and stay alive for the test.
            let (stream2, _) = listener.accept().await.unwrap();
            serve_handshake(stream2, 1234).await;
            tokio::time::sleep(Duration::from_millis(500)).await;
        });

        let client = DaemonClient::connect_with_backoff(
            &sock_path,
            Duration::from_millis(20),
            Duration::from_millis(100),
        )
        .await
        .expect("initial connect should succeed");

        let mut state_rx = client.connection_state();
        let mut msg_rx = client.subscribe();

        // Wait until the fake daemon signals that gen 1 has completed its
        // handshake and the stream is about to drop.
        gen1_done_rx.await.unwrap();

        // Wait for Reconnecting state.
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.expect("state watch closed");
                if matches!(*state_rx.borrow(), ConnectionState::Reconnecting { .. }) {
                    break;
                }
            }
        })
        .await
        .expect("timed out waiting for Reconnecting state");

        // Wait for Connected state after the reconnect.
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.expect("state watch closed");
                if matches!(*state_rx.borrow(), ConnectionState::Connected { .. }) {
                    break;
                }
            }
        })
        .await
        .expect("timed out waiting for Connected state after reconnect");

        // Verify that DaemonReconnected was broadcast to subscribers.
        let msg = tokio::time::timeout(Duration::from_secs(2), msg_rx.recv())
            .await
            .expect("timed out waiting for DaemonReconnected message")
            .expect("broadcast channel closed");

        assert!(
            matches!(msg, ServerMsg::DaemonReconnected),
            "expected DaemonReconnected, got {msg:?}"
        );

        fake_daemon.await.unwrap();
        let _ = std::fs::remove_file(&sock_path);
    }
}
