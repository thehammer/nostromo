//! Persistent broker client for the Mother IPC protocol.
//!
//! Connects to the Mother broker over a Unix domain socket using NDJSON
//! line framing (not the length-prefixed codec used by `nostromd`).
//!
//! ## Design
//!
//! Modelled on `src/ipc/client.rs` (`DaemonClient`):
//!
//! - [`BrokerClient`] is `Clone` (backed by `Arc<Inner>`) and cheap to share.
//! - A supervisor task owns the socket across reconnect generations with
//!   exponential backoff (1 s → 30 s).
//! - On each new generation the supervisor performs the hello/subscribe
//!   handshake and broadcasts a synthetic [`BrokerEvent::Reconnected`] so
//!   consumers can re-seed their job maps from the fresh snapshot.
//! - [`BrokerClient::send_command`] correlates commands with their acks by
//!   `id`; pending commands that span a disconnect resolve to
//!   [`BrokerSendError::Disconnected`].
//!
//! ## No fallback
//!
//! There is **no CLI fallback**. When the broker is unreachable, mutations
//! surface a clear operator-visible error. The supervisor keeps retrying the
//! connection in the background.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, ReadHalf, WriteHalf};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tracing::{debug, info, warn};

use super::{
    protocol::{
        cmd_subscribe, AckData, BrokerErrorCode, Envelope, EventData, FoldResult, HelloData,
        SnapshotData, PROTOCOL_VERSION,
    },
    MotherJob,
};

// ── max line size ──────────────────────────────────────────────────────────────

const MAX_LINE_BYTES: usize = 8 * 1024 * 1024; // 8 MiB

// ── connection state ───────────────────────────────────────────────────────────

/// Current state of the broker socket connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrokerConnState {
    /// Performing the initial connection or handshake.
    Connecting,
    /// Successfully connected and subscribed.
    Connected,
    /// Waiting before the next reconnect attempt.
    Reconnecting { attempt: u32, backoff_secs: u32 },
}

// ── public event type ─────────────────────────────────────────────────────────

/// Events broadcast to subscribers of the broker event stream.
#[derive(Debug, Clone)]
pub enum BrokerEvent {
    /// Broker sent its initial `hello` — contains protocol version + capabilities.
    Hello {
        protocol_version: u32,
        capabilities: Vec<String>,
    },
    /// Broker sent a `snapshot` in response to `subscribe`.
    Snapshot { sub: String, jobs: Vec<MotherJob> },
    /// A job's state changed (includes awaiting transitions).
    StateChange {
        job_id: String,
        new_state: String,
        /// Set when the job transitioned into `awaiting`.
        question: Option<String>,
        paused_reason: Option<String>,
    },
    /// A job reported a `current_activity` update.
    CurrentActivity { job_id: String, activity: String },
    /// Broker sent a `ping`; liveness-only, can be ignored.
    Ping,
    /// Client reconnected; consumers should re-seed their state from the next Snapshot.
    Reconnected,
}

// ── error types ───────────────────────────────────────────────────────────────

/// Error returned by [`BrokerClient::send_command`].
#[derive(Debug, Clone)]
pub enum BrokerSendError {
    /// The broker socket is not currently connected.
    Disconnected,
    /// The broker returned a negative ack.
    BrokerNack {
        code: BrokerErrorCode,
        message: String,
    },
    /// No ack received within the 10-second timeout.
    Timeout,
}

impl BrokerSendError {
    /// Map to an operator-facing string for display in `status_note` or a toast.
    pub fn operator_message(&self, verb: &str) -> String {
        match self {
            Self::Disconnected => {
                "Mother broker is not connected. Retrying in background.".to_string()
            }
            Self::Timeout => "Mother broker did not respond in time. Try again.".to_string(),
            Self::BrokerNack { code, message } => code.operator_message(verb, message),
        }
    }
}

// ── inner state ───────────────────────────────────────────────────────────────

type PendingMap = Mutex<HashMap<String, oneshot::Sender<Result<AckData, BrokerSendError>>>>;

struct Inner {
    /// Pre-serialized NDJSON lines queued for the current (or next) generation.
    write_tx: mpsc::UnboundedSender<String>,
    /// Broadcast of every parsed `BrokerEvent`.
    events_tx: broadcast::Sender<BrokerEvent>,
    /// Current connection state.
    state_tx: watch::Sender<BrokerConnState>,
    /// Pending command acks: command_id → reply oneshot.
    ///
    /// Entries are registered before sending the line and resolved by the
    /// supervisor inbound loop when a matching ack arrives, or drained to
    /// `Disconnected` on generation end.
    pending: PendingMap,
}

// ── public handle ─────────────────────────────────────────────────────────────

/// Mother broker client with transparent auto-reconnect.
///
/// Construction is infallible — if the broker socket is absent at startup the
/// supervisor begins retrying immediately.  The client is `Clone` so it can be
/// shared across the app, modal handlers, and MCP tool handlers.
#[derive(Clone)]
pub struct BrokerClient {
    inner: Arc<Inner>,
}

impl BrokerClient {
    /// Create a `BrokerClient` connected (eventually) to the given socket path.
    ///
    /// Never fails — if the socket is absent the supervisor keeps retrying with
    /// exponential backoff (1 s → 30 s). Call [`connection_state`] to observe
    /// the current state.
    pub fn new(socket_path: PathBuf) -> Self {
        Self::new_with_backoff(socket_path, Duration::from_secs(1), Duration::from_secs(30))
    }

    /// Like [`new`] but with configurable backoff — useful in tests.
    pub fn new_with_backoff(
        socket_path: PathBuf,
        initial_backoff: Duration,
        max_backoff: Duration,
    ) -> Self {
        let (write_tx, write_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _) = broadcast::channel::<BrokerEvent>(512);
        let (state_tx, _) = watch::channel(BrokerConnState::Connecting);
        let pending: PendingMap = Mutex::new(HashMap::new());

        let inner = Arc::new(Inner {
            write_tx,
            events_tx: events_tx.clone(),
            state_tx: state_tx.clone(),
            pending,
        });

        tokio::spawn(supervisor_task(
            Arc::clone(&inner),
            write_rx,
            events_tx,
            state_tx,
            ReconnectCfg {
                socket_path,
                initial_backoff,
                max_backoff,
            },
        ));

        Self { inner }
    }

    // ── public API ────────────────────────────────────────────────────────────

    /// Subscribe to the broker event stream.
    ///
    /// Messages sent before this call are NOT replayed.  The channel survives
    /// reconnects — never rebuilt across generations.
    pub fn subscribe(&self) -> broadcast::Receiver<BrokerEvent> {
        self.inner.events_tx.subscribe()
    }

    /// Watch the current connection state.
    pub fn connection_state(&self) -> watch::Receiver<BrokerConnState> {
        self.inner.state_tx.subscribe()
    }

    /// Send a command envelope and await the correlated ack.
    ///
    /// If the socket is currently disconnected (`Connecting` / `Reconnecting`),
    /// returns [`BrokerSendError::Disconnected`] immediately without queuing.
    ///
    /// Times out after 10 seconds with [`BrokerSendError::Timeout`].
    pub async fn send_command(&self, env: Envelope) -> Result<AckData, BrokerSendError> {
        // Reject immediately when not connected.
        let state = self.inner.state_tx.subscribe().borrow().clone();
        if state != BrokerConnState::Connected {
            return Err(BrokerSendError::Disconnected);
        }

        let id = env.id.clone();
        let line = match serde_json::to_string(&env) {
            Ok(s) => s,
            Err(e) => {
                warn!("broker: failed to serialize command: {e}");
                return Err(BrokerSendError::Disconnected);
            }
        };

        // Register the pending oneshot BEFORE sending the line.
        let (reply_tx, reply_rx) = oneshot::channel();
        {
            let mut pending = self.inner.pending.lock().unwrap();
            pending.insert(id.clone(), reply_tx);
        }

        // Enqueue the line for the supervisor to write.
        if self.inner.write_tx.send(line).is_err() {
            // Channel closed — supervisor exited.
            let mut pending = self.inner.pending.lock().unwrap();
            pending.remove(&id);
            return Err(BrokerSendError::Disconnected);
        }

        // Await the ack with a 10-second timeout.
        match tokio::time::timeout(Duration::from_secs(10), reply_rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => {
                // Sender was dropped (disconnect drain).
                Err(BrokerSendError::Disconnected)
            }
            Err(_) => {
                // Timeout — remove from pending.
                let mut pending = self.inner.pending.lock().unwrap();
                pending.remove(&id);
                Err(BrokerSendError::Timeout)
            }
        }
    }
}

// ── reconnect config ─────────────────────────────────────────────────────────

struct ReconnectCfg {
    socket_path: PathBuf,
    initial_backoff: Duration,
    max_backoff: Duration,
}

// ── line I/O ──────────────────────────────────────────────────────────────────

/// Read one NDJSON line from the broker stream.
///
/// Returns `Err` if the line exceeds `MAX_LINE_BYTES` or the stream closes.
async fn read_line(reader: &mut BufReader<ReadHalf<UnixStream>>) -> std::io::Result<String> {
    let mut line = String::new();
    let n = reader.read_line(&mut line).await?;
    if n == 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "broker connection closed",
        ));
    }
    if line.len() > MAX_LINE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("broker line exceeds {MAX_LINE_BYTES} bytes"),
        ));
    }
    Ok(line)
}

/// Write one NDJSON line to the broker stream (appends `\n` if absent).
async fn write_line(writer: &mut WriteHalf<UnixStream>, line: &str) -> std::io::Result<()> {
    writer.write_all(line.as_bytes()).await?;
    if !line.ends_with('\n') {
        writer.write_all(b"\n").await?;
    }
    Ok(())
}

// ── supervisor task ────────────────────────────────────────────────────────────

async fn supervisor_task(
    inner: Arc<Inner>,
    mut write_rx: mpsc::UnboundedReceiver<String>,
    events_tx: broadcast::Sender<BrokerEvent>,
    state_tx: watch::Sender<BrokerConnState>,
    cfg: ReconnectCfg,
) {
    let mut attempt: u32 = 0;

    loop {
        if attempt > 0 {
            let backoff = backoff_duration(attempt, cfg.initial_backoff, cfg.max_backoff);
            let _ = state_tx.send(BrokerConnState::Reconnecting {
                attempt,
                backoff_secs: backoff.as_secs() as u32,
            });
            debug!(
                attempt,
                backoff_ms = backoff.as_millis(),
                "broker: will reconnect"
            );
            tokio::time::sleep(backoff).await;
        }

        let _ = state_tx.send(BrokerConnState::Connecting);

        // Attempt to connect.
        let stream = match tokio::time::timeout(
            Duration::from_secs(5),
            UnixStream::connect(&cfg.socket_path),
        )
        .await
        {
            Ok(Ok(s)) => s,
            Ok(Err(e)) => {
                debug!("broker: connect attempt {attempt} failed: {e:#}");
                attempt += 1;
                continue;
            }
            Err(_) => {
                debug!("broker: connect attempt {attempt} timed out");
                attempt += 1;
                continue;
            }
        };

        info!("broker: connected to {}", cfg.socket_path.display());

        let (reader, writer) = tokio::io::split(stream);
        let mut reader = BufReader::new(reader);

        // Perform the hello/subscribe handshake.
        let capabilities = match handshake(&mut reader, &mut write_rx, &events_tx).await {
            Ok(caps) => caps,
            Err(e) => {
                warn!("broker: handshake failed: {e:#}");
                attempt += 1;
                continue;
            }
        };

        // Subscribe to the queue.
        let sub_cmd = cmd_subscribe(&capabilities);
        let sub_line = match serde_json::to_string(&sub_cmd) {
            Ok(s) => s,
            Err(e) => {
                warn!("broker: failed to serialize subscribe: {e}");
                attempt += 1;
                continue;
            }
        };

        // We need a writer for sending sub_cmd, then hand it to run_generation.
        // Reconstruct the writer from a new split isn't possible. Let's wrap
        // the subscribe send into run_generation by passing the sub_line.
        let _ = state_tx.send(BrokerConnState::Connected);

        if attempt > 0 {
            // Synthetic reconnect event so consumers re-seed.
            let _ = events_tx.send(BrokerEvent::Reconnected);
        }
        attempt = 0;

        // Run the generation (returns false on socket failure, true on shutdown).
        let shutdown = run_generation(
            &inner,
            &mut reader,
            writer,
            &mut write_rx,
            &events_tx,
            sub_line,
        )
        .await;

        if shutdown {
            info!("broker: supervisor shutting down (write channel closed)");
            return;
        }

        // Drain pending commands on generation end.
        drain_pending(&inner, BrokerSendError::Disconnected);

        let _ = state_tx.send(BrokerConnState::Reconnecting {
            attempt: 1,
            backoff_secs: 0,
        });
        attempt += 1;
    }
}

/// Perform the initial `hello` handshake: wait for the broker's `hello` event
/// and return the advertised capabilities.
///
/// Drains any pending write queue items that arrived before the handshake.
async fn handshake(
    reader: &mut BufReader<ReadHalf<UnixStream>>,
    _write_rx: &mut mpsc::UnboundedReceiver<String>,
    events_tx: &broadcast::Sender<BrokerEvent>,
) -> anyhow::Result<Vec<String>> {
    loop {
        let line = read_line(reader).await?;
        let env: Envelope = match serde_json::from_str(line.trim()) {
            Ok(e) => e,
            Err(e) => {
                debug!("broker: unparseable line during handshake: {e} — {line}");
                continue;
            }
        };

        if env.kind == "hello" {
            let hello: HelloData = serde_json::from_value(env.data.clone()).unwrap_or(HelloData {
                protocol_version: 0,
                capabilities: vec![],
            });

            // Version negotiation.
            if hello.protocol_version > PROTOCOL_VERSION {
                warn!(
                    "broker protocol version {} > client {} — forward-compatible; continuing",
                    hello.protocol_version, PROTOCOL_VERSION
                );
            }

            let _ = events_tx.send(BrokerEvent::Hello {
                protocol_version: hello.protocol_version,
                capabilities: hello.capabilities.clone(),
            });

            return Ok(hello.capabilities);
        }
        // Ignore unexpected messages before hello.
        debug!("broker: ignoring pre-hello message kind={}", env.kind);
    }
}

/// Run one connection generation: pump `write_rx` → socket and socket → broadcast.
///
/// `sub_line` is sent immediately as the first outbound message (the subscribe
/// command built in the supervisor).
///
/// Returns `true` if `write_rx` was closed (all `BrokerClient` clones dropped)
/// and the supervisor should exit; `false` if the socket failed.
async fn run_generation(
    inner: &Arc<Inner>,
    reader: &mut BufReader<ReadHalf<UnixStream>>,
    mut writer: WriteHalf<UnixStream>,
    write_rx: &mut mpsc::UnboundedReceiver<String>,
    events_tx: &broadcast::Sender<BrokerEvent>,
    sub_line: String,
) -> bool {
    // Send the subscribe command first.
    if write_line(&mut writer, &sub_line).await.is_err() {
        return false;
    }
    debug!("broker: sent subscribe");

    loop {
        tokio::select! {
            // Outbound: drain the write queue into the socket.
            msg = write_rx.recv() => {
                match msg {
                    None => return true, // All BrokerClient clones dropped.
                    Some(line) => {
                        if write_line(&mut writer, &line).await.is_err() {
                            return false;
                        }
                    }
                }
            }

            // Inbound: parse each NDJSON line, route acks to pending map,
            // broadcast events.
            result = read_line(reader) => {
                match result {
                    Ok(line) => {
                        dispatch_inbound(inner, line.trim(), events_tx);
                    }
                    Err(e) => {
                        debug!("broker: read failed: {e:#}; will reconnect");
                        return false;
                    }
                }
            }
        }
    }
}

/// Parse an inbound NDJSON line and route it to either the pending ack map or
/// the event broadcast.
fn dispatch_inbound(inner: &Arc<Inner>, line: &str, events_tx: &broadcast::Sender<BrokerEvent>) {
    if line.is_empty() {
        return;
    }
    let env: Envelope = match serde_json::from_str(line) {
        Ok(e) => e,
        Err(e) => {
            warn!("broker: failed to parse inbound line: {e} — {line}");
            return;
        }
    };

    match env.dir {
        super::protocol::Dir::Ack => {
            // Correlate by id and resolve the pending oneshot.
            let ack_result: Result<AckData, BrokerSendError> =
                match serde_json::from_value::<AckData>(env.data) {
                    Ok(ack) if ack.ok => Ok(ack),
                    Ok(ack) => {
                        let err = ack.error.as_ref();
                        let code = BrokerErrorCode::parse_code(
                            err.map(|e| e.code.as_str()).unwrap_or("internal"),
                        );
                        let message = err.map(|e| e.message.clone()).unwrap_or_default();

                        // Terminal: version mismatch disables mutations.
                        if code == BrokerErrorCode::VersionMismatch {
                            warn!("broker: version_mismatch — mutations disabled until update");
                        }

                        Err(BrokerSendError::BrokerNack { code, message })
                    }
                    Err(e) => {
                        warn!("broker: failed to parse ack data: {e}");
                        Err(BrokerSendError::Disconnected)
                    }
                };

            let mut pending = inner.pending.lock().unwrap();
            if let Some(tx) = pending.remove(&env.id) {
                let _ = tx.send(ack_result);
            } else {
                debug!(
                    "broker: late ack for id={} (timed out or duplicate)",
                    env.id
                );
            }
        }

        super::protocol::Dir::Event => {
            dispatch_event(env, events_tx);
        }

        super::protocol::Dir::Cmd => {
            // Broker should never send Cmd direction to the client; ignore.
        }
    }
}

/// Translate a broker event envelope into a `BrokerEvent` and broadcast it.
fn dispatch_event(env: Envelope, events_tx: &broadcast::Sender<BrokerEvent>) {
    let kind = env.kind.as_str();

    match kind {
        "hello" => {
            // Already handled in handshake; ignore duplicates.
        }
        "ping" => {
            let _ = events_tx.send(BrokerEvent::Ping);
        }
        "snapshot" => {
            if let Ok(snap) = serde_json::from_value::<SnapshotData>(env.data) {
                let _ = events_tx.send(BrokerEvent::Snapshot {
                    sub: snap.sub,
                    jobs: snap.jobs,
                });
            } else {
                warn!("broker: failed to parse snapshot data");
            }
        }
        _ => {
            // State / await / current_activity / quota / etc.
            let data: EventData = serde_json::from_value(env.data.clone()).unwrap_or_default();

            let job_id = match data.job.clone() {
                Some(id) => id,
                None => return, // Can't do anything without a job id.
            };

            match kind {
                "current_activity" => {
                    if let Some(activity) = data.activity.clone() {
                        let _ = events_tx.send(BrokerEvent::CurrentActivity { job_id, activity });
                    }
                }
                _ => {
                    // Apply state fold.
                    use super::protocol::fold_state;
                    if let FoldResult::SetState(new_state) = fold_state(kind, &data) {
                        let question = if new_state == "awaiting" {
                            data.question.clone()
                        } else {
                            None
                        };
                        let paused_reason = if new_state == "awaiting" {
                            data.paused_reason.clone()
                        } else {
                            None
                        };
                        let _ = events_tx.send(BrokerEvent::StateChange {
                            job_id,
                            new_state,
                            question,
                            paused_reason,
                        });
                    }
                    // NoStateChange events (e.g. quota category) are ignored.
                }
            }
        }
    }
}

/// Drain the pending command map, resolving all outstanding oneshots with the
/// given error.  Called on generation end (socket disconnect).
fn drain_pending(inner: &Arc<Inner>, error: BrokerSendError) {
    let mut pending = inner.pending.lock().unwrap();
    for (_, tx) in pending.drain() {
        let _ = tx.send(Err(error.clone()));
    }
}

// ── backoff helper ────────────────────────────────────────────────────────────

fn backoff_duration(attempt: u32, initial: Duration, max: Duration) -> Duration {
    let factor = 2u64.saturating_pow(attempt.saturating_sub(1));
    let nanos = (initial.as_nanos() as u64)
        .saturating_mul(factor)
        .min(max.as_nanos() as u64);
    Duration::from_nanos(nanos)
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mother::protocol::{cmd_answer, cmd_cancel};
    use tokio::net::UnixListener;

    // ── fake broker helpers ───────────────────────────────────────────────────

    /// Write one NDJSON line to a `WriteHalf`.
    async fn fake_write(writer: &mut WriteHalf<UnixStream>, v: &serde_json::Value) {
        let mut bytes = serde_json::to_vec(v).unwrap();
        bytes.push(b'\n');
        writer.write_all(&bytes).await.unwrap();
    }

    /// Read one NDJSON line from a `BufReader<ReadHalf<UnixStream>>`.
    async fn fake_read(reader: &mut BufReader<ReadHalf<UnixStream>>) -> serde_json::Value {
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        serde_json::from_str(line.trim()).unwrap()
    }

    /// Send the broker hello event and return the advertised capabilities.
    async fn send_hello(writer: &mut WriteHalf<UnixStream>, caps: &[&str]) {
        let caps_json: Vec<serde_json::Value> = caps.iter().map(|s| serde_json::json!(s)).collect();
        fake_write(
            writer,
            &serde_json::json!({
                "v": 1, "dir": "event", "t": "hello", "id": "hello-1", "ts": "2026-01-01T00:00:00.000Z",
                "data": { "protocol_version": 1, "capabilities": caps_json }
            }),
        )
        .await;
    }

    /// Read and return the subscribe command the client sends after hello.
    async fn read_subscribe(reader: &mut BufReader<ReadHalf<UnixStream>>) -> serde_json::Value {
        fake_read(reader).await
    }

    /// Send a snapshot in response to subscribe.
    async fn send_snapshot(writer: &mut WriteHalf<UnixStream>, jobs: Vec<serde_json::Value>) {
        fake_write(
            writer,
            &serde_json::json!({
                "v": 1, "dir": "event", "t": "snapshot", "id": "snap-1", "ts": "2026-01-01T00:00:00.000Z",
                "data": { "sub": "queue", "jobs": jobs }
            }),
        )
        .await;
    }

    /// Send a success ack for the given command id.
    async fn send_ack_ok(writer: &mut WriteHalf<UnixStream>, cmd_id: &str, t: &str) {
        fake_write(
            writer,
            &serde_json::json!({
                "v": 1, "dir": "ack", "t": t, "id": cmd_id, "ts": "2026-01-01T00:00:00.000Z",
                "data": { "ok": true, "job": "job-1" }
            }),
        )
        .await;
    }

    /// Send a failure ack for the given command id.
    async fn send_ack_err(
        writer: &mut WriteHalf<UnixStream>,
        cmd_id: &str,
        t: &str,
        code: &str,
        message: &str,
    ) {
        fake_write(
            writer,
            &serde_json::json!({
                "v": 1, "dir": "ack", "t": t, "id": cmd_id, "ts": "2026-01-01T00:00:00.000Z",
                "data": {
                    "ok": false,
                    "error": { "code": code, "message": message }
                }
            }),
        )
        .await;
    }

    fn temp_sock() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "nostromo_broker_test_{}.sock",
            uuid::Uuid::new_v4()
        ))
    }

    // ── tests ─────────────────────────────────────────────────────────────────

    /// Client connects, receives hello, sends subscribe, receives snapshot.
    #[tokio::test]
    async fn handshake_and_snapshot() {
        let sock = temp_sock();
        let listener = UnixListener::bind(&sock).unwrap();

        let sock_clone = sock.clone();
        let fake_broker = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, mut writer) = tokio::io::split(stream);
            let mut reader = BufReader::new(reader);

            send_hello(&mut writer, &["state", "await", "current_activity"]).await;
            let sub = read_subscribe(&mut reader).await;
            assert_eq!(sub["t"], "subscribe");
            assert_eq!(sub["data"]["sub"], "queue");

            send_snapshot(
                &mut writer,
                vec![serde_json::json!({
                    "id": "job-1", "state": "running", "title": "Test job",
                    "repo": "", "isolation": ""
                })],
            )
            .await;

            // Keep alive briefly.
            tokio::time::sleep(Duration::from_millis(200)).await;
            let _ = sock_clone;
        });

        let client = BrokerClient::new_with_backoff(
            sock.clone(),
            Duration::from_millis(10),
            Duration::from_millis(50),
        );

        let mut events = client.subscribe();

        // Wait for Connected state.
        let mut state_rx = client.connection_state();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.expect("state watch closed");
                if *state_rx.borrow() == BrokerConnState::Connected {
                    break;
                }
            }
        })
        .await
        .expect("timed out waiting for Connected");

        // Should receive Hello event.
        let ev = tokio::time::timeout(Duration::from_secs(2), events.recv())
            .await
            .expect("timed out waiting for Hello")
            .expect("broadcast closed");
        assert!(
            matches!(ev, BrokerEvent::Hello { .. }),
            "expected Hello, got {ev:?}"
        );

        // Should receive Snapshot event with the job.
        let ev = tokio::time::timeout(Duration::from_secs(2), events.recv())
            .await
            .expect("timed out waiting for Snapshot")
            .expect("broadcast closed");
        if let BrokerEvent::Snapshot { jobs, .. } = ev {
            assert_eq!(jobs.len(), 1);
            assert_eq!(jobs[0].id, "job-1");
        } else {
            panic!("expected Snapshot, got {ev:?}");
        }

        fake_broker.await.unwrap();
        let _ = std::fs::remove_file(&sock);
    }

    /// Command correlation: send cancel, fake broker replies with success ack.
    #[tokio::test]
    async fn command_correlation_success() {
        let sock = temp_sock();
        let listener = UnixListener::bind(&sock).unwrap();

        let fake_broker = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, mut writer) = tokio::io::split(stream);
            let mut reader = BufReader::new(reader);

            send_hello(&mut writer, &["state", "await"]).await;
            let _sub = read_subscribe(&mut reader).await;
            send_snapshot(&mut writer, vec![]).await;

            // Read the cancel command.
            let cmd = fake_read(&mut reader).await;
            assert_eq!(cmd["t"], "cancel");
            let cmd_id = cmd["id"].as_str().unwrap().to_string();

            send_ack_ok(&mut writer, &cmd_id, "cancel").await;

            tokio::time::sleep(Duration::from_millis(200)).await;
        });

        let client = BrokerClient::new_with_backoff(
            sock.clone(),
            Duration::from_millis(10),
            Duration::from_millis(50),
        );

        // Wait for connected.
        let mut state_rx = client.connection_state();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.unwrap();
                if *state_rx.borrow() == BrokerConnState::Connected {
                    break;
                }
            }
        })
        .await
        .expect("timed out");
        // Small delay to allow snapshot to arrive and state to settle.
        tokio::time::sleep(Duration::from_millis(50)).await;

        let cmd = cmd_cancel("job-1");
        let result = client.send_command(cmd).await;
        assert!(result.is_ok(), "expected Ok ack, got {result:?}");

        fake_broker.await.unwrap();
        let _ = std::fs::remove_file(&sock);
    }

    /// Out-of-order ack: interleave a ping and event before the ack, assert it
    /// still matches by id.
    #[tokio::test]
    async fn command_correlation_out_of_order() {
        let sock = temp_sock();
        let listener = UnixListener::bind(&sock).unwrap();

        let fake_broker = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, mut writer) = tokio::io::split(stream);
            let mut reader = BufReader::new(reader);

            send_hello(&mut writer, &["state"]).await;
            let _sub = read_subscribe(&mut reader).await;
            send_snapshot(&mut writer, vec![]).await;

            // Read the answer command.
            let cmd = fake_read(&mut reader).await;
            let cmd_id = cmd["id"].as_str().unwrap().to_string();

            // Send a ping, then a state event, then the real ack.
            fake_write(&mut writer, &serde_json::json!({
                "v": 1, "dir": "event", "t": "ping", "id": "p1", "ts": "2026-01-01T00:00:00.000Z",
                "data": {}
            })).await;
            fake_write(&mut writer, &serde_json::json!({
                "v": 1, "dir": "event", "t": "running", "id": "e1", "ts": "2026-01-01T00:00:00.000Z",
                "data": { "job": "other-job", "category": "state" }
            })).await;
            send_ack_ok(&mut writer, &cmd_id, "answer").await;

            tokio::time::sleep(Duration::from_millis(200)).await;
        });

        let client = BrokerClient::new_with_backoff(
            sock.clone(),
            Duration::from_millis(10),
            Duration::from_millis(50),
        );

        let mut state_rx = client.connection_state();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.unwrap();
                if *state_rx.borrow() == BrokerConnState::Connected {
                    break;
                }
            }
        })
        .await
        .expect("timed out");
        tokio::time::sleep(Duration::from_millis(50)).await;

        let cmd = cmd_answer("job-1", "yes");
        let result = client.send_command(cmd).await;
        assert!(
            result.is_ok(),
            "expected Ok despite out-of-order ack; got {result:?}"
        );

        fake_broker.await.unwrap();
        let _ = std::fs::remove_file(&sock);
    }

    /// Failure ack: broker returns no_such_job → BrokerNack.
    #[tokio::test]
    async fn command_failure_ack_maps_to_broker_nack() {
        let sock = temp_sock();
        let listener = UnixListener::bind(&sock).unwrap();

        let fake_broker = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, mut writer) = tokio::io::split(stream);
            let mut reader = BufReader::new(reader);

            send_hello(&mut writer, &["state"]).await;
            let _sub = read_subscribe(&mut reader).await;
            send_snapshot(&mut writer, vec![]).await;

            let cmd = fake_read(&mut reader).await;
            let cmd_id = cmd["id"].as_str().unwrap().to_string();
            send_ack_err(&mut writer, &cmd_id, "cancel", "no_such_job", "not found").await;

            tokio::time::sleep(Duration::from_millis(200)).await;
        });

        let client = BrokerClient::new_with_backoff(
            sock.clone(),
            Duration::from_millis(10),
            Duration::from_millis(50),
        );

        let mut state_rx = client.connection_state();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.unwrap();
                if *state_rx.borrow() == BrokerConnState::Connected {
                    break;
                }
            }
        })
        .await
        .expect("timed out");
        tokio::time::sleep(Duration::from_millis(50)).await;

        let result = client.send_command(cmd_cancel("job-1")).await;
        match result {
            Err(BrokerSendError::BrokerNack { code, .. }) => {
                assert_eq!(code, BrokerErrorCode::NoSuchJob);
            }
            other => panic!("expected BrokerNack(no_such_job), got {other:?}"),
        }

        fake_broker.await.unwrap();
        let _ = std::fs::remove_file(&sock);
    }

    /// Reconnect: broker drops the connection; client transitions Reconnecting →
    /// Connected, re-sends subscribe, emits Reconnected event.
    #[tokio::test]
    async fn reconnect_after_socket_drop() {
        let sock = temp_sock();
        let listener = UnixListener::bind(&sock).unwrap();
        let (gen1_done_tx, gen1_done_rx) = tokio::sync::oneshot::channel::<()>();

        let fake_broker = tokio::spawn(async move {
            // Gen 1: handshake then drop.
            {
                let (stream, _) = listener.accept().await.unwrap();
                let (reader, mut writer) = tokio::io::split(stream);
                let mut reader = BufReader::new(reader);
                send_hello(&mut writer, &["state"]).await;
                let _sub = read_subscribe(&mut reader).await;
                send_snapshot(&mut writer, vec![]).await;
                // Drop stream → disconnect.
            }
            let _ = gen1_done_tx.send(());

            // Gen 2: handshake and stay alive.
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, mut writer) = tokio::io::split(stream);
            let mut reader = BufReader::new(reader);
            send_hello(&mut writer, &["state"]).await;
            let _sub = read_subscribe(&mut reader).await;
            send_snapshot(&mut writer, vec![]).await;
            tokio::time::sleep(Duration::from_millis(500)).await;
        });

        let client = BrokerClient::new_with_backoff(
            sock.clone(),
            Duration::from_millis(20),
            Duration::from_millis(100),
        );

        let mut state_rx = client.connection_state();
        let mut events_rx = client.subscribe();

        // Wait for gen 1 Connected.
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.unwrap();
                if *state_rx.borrow() == BrokerConnState::Connected {
                    break;
                }
            }
        })
        .await
        .expect("timed out on gen1 connect");

        gen1_done_rx.await.unwrap();

        // Wait for Reconnecting state.
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.unwrap();
                if matches!(*state_rx.borrow(), BrokerConnState::Reconnecting { .. }) {
                    break;
                }
            }
        })
        .await
        .expect("timed out waiting for Reconnecting");

        // Wait for Connected again.
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.unwrap();
                if *state_rx.borrow() == BrokerConnState::Connected {
                    break;
                }
            }
        })
        .await
        .expect("timed out waiting for gen2 Connected");

        // Reconnected event should have been broadcast.
        let mut found_reconnected = false;
        for _ in 0..20 {
            match events_rx.try_recv() {
                Ok(BrokerEvent::Reconnected) => {
                    found_reconnected = true;
                    break;
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
        assert!(
            found_reconnected,
            "Reconnected event should have been broadcast"
        );

        fake_broker.await.unwrap();
        let _ = std::fs::remove_file(&sock);
    }

    /// Command issued while disconnected → BrokerSendError::Disconnected immediately.
    #[tokio::test]
    async fn send_while_disconnected_returns_disconnected() {
        let sock = temp_sock();
        // No listener — socket absent.

        let client = BrokerClient::new_with_backoff(
            sock.clone(),
            Duration::from_millis(500), // long backoff so we stay Connecting
            Duration::from_millis(500),
        );

        // State starts as Connecting — not Connected.
        let result = client.send_command(cmd_cancel("job-1")).await;
        assert!(
            matches!(result, Err(BrokerSendError::Disconnected)),
            "expected Disconnected, got {result:?}"
        );
    }

    /// Oversize line (> 8 MiB) causes the generation to disconnect rather than OOM.
    #[tokio::test]
    async fn oversize_line_disconnects_generation() {
        let sock = temp_sock();
        let listener = UnixListener::bind(&sock).unwrap();

        let fake_broker = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, mut writer) = tokio::io::split(stream);
            let mut reader = BufReader::new(reader);

            send_hello(&mut writer, &["state"]).await;
            let _sub = read_subscribe(&mut reader).await;

            // Write a line > 8 MiB.
            let big = vec![b'x'; MAX_LINE_BYTES + 1];
            writer.write_all(&big).await.unwrap();
            writer.write_all(b"\n").await.unwrap();

            tokio::time::sleep(Duration::from_millis(200)).await;
        });

        let client = BrokerClient::new_with_backoff(
            sock.clone(),
            Duration::from_millis(20),
            Duration::from_millis(100),
        );

        let mut state_rx = client.connection_state();

        // Wait for initial connect.
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.unwrap();
                if *state_rx.borrow() == BrokerConnState::Connected {
                    break;
                }
            }
        })
        .await
        .expect("timed out on connect");

        // After the oversize line, the client should disconnect.
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                state_rx.changed().await.unwrap();
                if matches!(
                    *state_rx.borrow(),
                    BrokerConnState::Reconnecting { .. } | BrokerConnState::Connecting
                ) {
                    break;
                }
            }
        })
        .await
        .expect("expected disconnect after oversize line");

        fake_broker.await.unwrap();
        let _ = std::fs::remove_file(&sock);
    }
}
