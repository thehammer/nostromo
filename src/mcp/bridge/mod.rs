//! The reconnecting stdio ↔ Unix socket proxy behind `nostromo-mcp-bridge`.
//!
//! Claude Code never respawns a dead stdio MCP server, so the bridge must
//! outlive the daemon connection it fronts: it exits only when its stdin
//! closes (the client is gone) or on a fatal local error.
//!
//! ## Shape
//!
//! One thread reads stdin into a channel, one thread per connection reads the
//! socket into the same channel, and the main thread owns all state and all
//! writes. Frames are newline-delimited; bytes are forwarded untouched (frames
//! are parsed only to track request ids and spot the handshake).
//!
//! ## On a dropped connection
//!
//! * requests sent and not yet answered get a JSON-RPC `-32000` error with
//!   their own id, so the client never hangs;
//! * the bridge reconnects with jittered exponential backoff, re-sends the
//!   Hello frame (same `pty_id`) and replays the handshake: the saved
//!   `initialize` (its response is swallowed) and `notifications/initialized`,
//!   then tells the client `notifications/tools/list_changed`;
//! * frames the client sends meanwhile are queued (bounded) and delivered
//!   after the replay.
//!
//! Logging is content-free: see [`BridgeLog`].

mod backoff;
mod log;

pub use backoff::Backoff;
pub use log::{BridgeLog, MAX_LOG_BYTES, MAX_LOG_FILES};

use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

/// Most frames held for delivery while disconnected.
pub const QUEUE_MAX_FRAMES: usize = 256;
/// Most bytes (frames plus their newlines) held while disconnected.
pub const QUEUE_MAX_BYTES: usize = 1024 * 1024;

/// JSON-RPC error code and text a client gets for a request the dropped
/// connection could not answer. The bridge cannot tell "never reached the
/// daemon" from "ran, but the response was lost", so the text must not invite
/// a blind retry.
pub const LOST_CODE: i64 = -32000;
pub const LOST_MESSAGE: &str = "nostromo daemon connection lost; the outcome of this call is unknown; check state before retrying";

const DEFAULT_BACKOFF_MIN: Duration = Duration::from_millis(100);
const DEFAULT_BACKOFF_MAX: Duration = Duration::from_secs(5);
/// How long the replayed `initialize` may go unanswered.
const REPLAY_TIMEOUT: Duration = Duration::from_secs(10);
/// A socket write that blocks this long means the daemon is wedged.
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);
/// A connection that lived this long (and heard from the daemon) was healthy:
/// its drop restarts the backoff schedule.
const STABLE_AFTER: Duration = Duration::from_secs(1);

// ── configuration ─────────────────────────────────────────────────────────────

/// A source of jitter values in `[0, 1)`.
pub type JitterSource = Arc<dyn Fn() -> f64 + Send + Sync>;
/// Told `(attempt, delay)` each time a reconnect is scheduled.
pub type ScheduleObserver = Arc<dyn Fn(u32, Duration) + Send + Sync>;

pub struct BridgeConfig {
    pub socket_path: PathBuf,
    pub pty_id: String,
    pub backoff: Backoff,
    /// Where to write `mcp-bridge-<pid>.log`; `None` disables logging.
    pub log_dir: Option<PathBuf>,
    /// Jitter for the backoff schedule (production: random).
    pub jitter: JitterSource,
    /// Observes every scheduled reconnect delay (production: none).
    pub on_schedule: Option<ScheduleObserver>,
}

impl BridgeConfig {
    pub fn new(
        socket_path: PathBuf,
        pty_id: String,
        backoff: Backoff,
        log_dir: Option<PathBuf>,
    ) -> Self {
        Self {
            socket_path,
            pty_id,
            backoff,
            log_dir,
            jitter: Arc::new(backoff::random_unit),
            on_schedule: None,
        }
    }

    /// `NOSTROMO_MCP_SOCKET`, `NOSTROMO_PTY_ID`, and the test hooks
    /// `NOSTROMO_MCP_BRIDGE_BACKOFF_MIN_MS` / `..._MAX_MS`.
    pub fn from_env() -> Self {
        let home = dirs_next::home_dir();
        let socket_path = std::env::var("NOSTROMO_MCP_SOCKET")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                home.clone()
                    .unwrap_or_else(|| PathBuf::from("/tmp"))
                    .join(".nostromo")
                    .join("mcp.sock")
            });
        let millis = |name: &str, default: Duration| {
            std::env::var(name)
                .ok()
                .and_then(|v| v.parse::<u64>().ok())
                .map_or(default, Duration::from_millis)
        };
        Self::new(
            socket_path,
            std::env::var("NOSTROMO_PTY_ID").unwrap_or_default(),
            Backoff::new(
                millis("NOSTROMO_MCP_BRIDGE_BACKOFF_MIN_MS", DEFAULT_BACKOFF_MIN),
                millis("NOSTROMO_MCP_BRIDGE_BACKOFF_MAX_MS", DEFAULT_BACKOFF_MAX),
            ),
            home.map(|h| h.join(".nostromo").join("logs")),
        )
    }
}

/// Run the bridge on the process's stdin/stdout. Returns the exit code.
pub fn run(config: BridgeConfig) -> i32 {
    run_with(config, std::io::stdin(), std::io::stdout())
}

/// [`run`] over arbitrary client streams.
pub fn run_with<R, W>(config: BridgeConfig, input: R, output: W) -> i32
where
    R: Read + Send + 'static,
    W: Write,
{
    let (tx, rx) = mpsc::channel();
    spawn_stdin_reader(input, tx.clone());
    let log = config
        .log_dir
        .as_deref()
        .and_then(|dir| BridgeLog::open(dir, std::process::id()).ok());
    let mut proxy = Proxy::new(config, output, log, tx, rx);
    proxy.log("started", None);
    match proxy.run() {
        Ok(code) => code,
        Err(Exit(code)) => code,
    }
}

// ── events ────────────────────────────────────────────────────────────────────

enum Event {
    /// A line from the client (newline removed).
    Stdin(Vec<u8>),
    StdinClosed,
    /// A line from connection `generation` (newline removed).
    Socket {
        generation: u64,
        line: Vec<u8>,
    },
    SocketEof {
        generation: u64,
    },
    SocketError {
        generation: u64,
    },
}

fn spawn_stdin_reader<R: Read + Send + 'static>(input: R, tx: Sender<Event>) {
    std::thread::spawn(move || {
        let mut reader = BufReader::new(input);
        loop {
            let mut buf = Vec::new();
            match reader.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    if buf.last() == Some(&b'\n') {
                        buf.pop();
                    }
                    if tx.send(Event::Stdin(buf)).is_err() {
                        return;
                    }
                }
            }
        }
        let _ = tx.send(Event::StdinClosed);
    });
}

fn spawn_socket_reader(stream: UnixStream, generation: u64, tx: Sender<Event>) {
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stream);
        loop {
            let mut buf = Vec::new();
            match reader.read_until(b'\n', &mut buf) {
                Ok(0) => {
                    let _ = tx.send(Event::SocketEof { generation });
                    return;
                }
                Ok(_) => {
                    if buf.last() != Some(&b'\n') {
                        // EOF in the middle of a frame: the frame is lost.
                        let _ = tx.send(Event::SocketEof { generation });
                        return;
                    }
                    buf.pop();
                    if tx
                        .send(Event::Socket {
                            generation,
                            line: buf,
                        })
                        .is_err()
                    {
                        return;
                    }
                }
                Err(_) => {
                    let _ = tx.send(Event::SocketError { generation });
                    return;
                }
            }
        }
    });
}

// ── frame classification ──────────────────────────────────────────────────────

enum Kind {
    Request { id: Value, method: String },
    Notification { method: String },
    Response { id: Value },
    Other,
}

fn classify(frame: &[u8]) -> Kind {
    if frame.iter().find(|b| !b.is_ascii_whitespace()) != Some(&b'{') {
        return Kind::Other;
    }
    let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(frame) else {
        return Kind::Other;
    };
    let method = obj.get("method").and_then(Value::as_str);
    let id = obj.get("id").filter(|v| !v.is_null());
    match (method, id) {
        (Some(method), Some(id)) => Kind::Request {
            id: id.clone(),
            method: method.to_string(),
        },
        (Some(method), None) => Kind::Notification {
            method: method.to_string(),
        },
        (None, Some(id)) if obj.contains_key("result") || obj.contains_key("error") => {
            Kind::Response { id: id.clone() }
        }
        _ => Kind::Other,
    }
}

// ── the proxy ─────────────────────────────────────────────────────────────────

/// A fatal local error (or clean stop): the process should exit with this code.
struct Exit(i32);

enum Phase {
    /// Waiting for the daemon to answer the replayed `initialize`.
    Replaying {
        deadline: Instant,
        init_id: Value,
    },
    Ready,
}

struct Connection {
    stream: UnixStream,
    generation: u64,
    phase: Phase,
    since: Instant,
    heard_from_daemon: bool,
}

/// A client handshake frame we may have to replay.
#[derive(Default)]
struct Handshake {
    frame: Option<Vec<u8>>,
    id: Option<Value>,
    /// Written to some daemon connection (as opposed to merely received).
    delivered: bool,
}

struct Queued {
    frame: Vec<u8>,
    kind: Kind,
}

struct Proxy<W: Write> {
    config: BridgeConfig,
    out: W,
    log: Option<BridgeLog>,
    tx: Sender<Event>,
    rx: mpsc::Receiver<Event>,

    conn: Option<Connection>,
    generation: u64,
    next_attempt: Instant,
    /// Consecutive failed attempts (connects, replays, short-lived links).
    failures: u32,
    ever_connected: bool,

    queue: VecDeque<Queued>,
    queue_bytes: usize,
    /// Requests sent to the daemon and not yet answered, in send order.
    in_flight: HashMap<String, (u64, Value)>,
    sent: u64,

    init: Handshake,
    initialized: Handshake,
}

impl<W: Write> Proxy<W> {
    fn new(
        config: BridgeConfig,
        out: W,
        log: Option<BridgeLog>,
        tx: Sender<Event>,
        rx: mpsc::Receiver<Event>,
    ) -> Self {
        Self {
            config,
            out,
            log,
            tx,
            rx,
            conn: None,
            generation: 0,
            next_attempt: Instant::now(),
            failures: 0,
            ever_connected: false,
            queue: VecDeque::new(),
            queue_bytes: 0,
            in_flight: HashMap::new(),
            sent: 0,
            init: Handshake::default(),
            initialized: Handshake::default(),
        }
    }

    fn log(&mut self, event: &str, attempt: Option<u32>) {
        let pty = self.config.pty_id.clone();
        if let Some(log) = self.log.as_mut() {
            log.line(&pty, event, attempt);
        }
    }

    fn run(&mut self) -> Result<i32, Exit> {
        loop {
            if self.conn.is_none() && Instant::now() >= self.next_attempt {
                self.try_connect()?;
                continue;
            }
            let wake = match &self.conn {
                None => Some(self.next_attempt),
                Some(Connection {
                    phase: Phase::Replaying { deadline, .. },
                    ..
                }) => Some(*deadline),
                Some(_) => None,
            };
            let event = match wake {
                None => self.rx.recv().ok(),
                Some(at) => {
                    match self
                        .rx
                        .recv_timeout(at.saturating_duration_since(Instant::now()))
                    {
                        Ok(event) => Some(event),
                        Err(RecvTimeoutError::Timeout) => {
                            self.check_replay_deadline()?;
                            continue;
                        }
                        Err(RecvTimeoutError::Disconnected) => None,
                    }
                }
            };
            let Some(event) = event else {
                return Ok(0);
            };
            match event {
                Event::Stdin(frame) => self.on_client_frame(frame)?,
                Event::StdinClosed => {
                    self.log("stdin_closed", None);
                    if let Some(conn) = self.conn.take() {
                        let _ = conn.stream.shutdown(Shutdown::Both);
                    }
                    return Ok(0);
                }
                Event::Socket { generation, line } if self.is_current(generation) => {
                    self.on_daemon_frame(line)?;
                }
                Event::SocketEof { generation } if self.is_current(generation) => {
                    self.connection_lost("socket_eof")?;
                }
                Event::SocketError { generation } if self.is_current(generation) => {
                    self.connection_lost("socket_error")?;
                }
                // A late event from a connection we already dropped.
                Event::Socket { .. } | Event::SocketEof { .. } | Event::SocketError { .. } => {}
            }
        }
    }

    fn is_current(&self, generation: u64) -> bool {
        self.conn
            .as_ref()
            .is_some_and(|c| c.generation == generation)
    }

    // ── connecting ───────────────────────────────────────────────────────────

    fn try_connect(&mut self) -> Result<(), Exit> {
        let attempt = self.failures + 1;
        let stream = match self.open_stream() {
            Ok(stream) => stream,
            Err(_) => {
                self.log("connect_failed", Some(attempt));
                self.schedule_after_failure();
                return Ok(());
            }
        };
        self.generation += 1;
        let generation = self.generation;
        let Ok(reader) = stream.try_clone() else {
            self.log("connect_failed", Some(attempt));
            self.schedule_after_failure();
            return Ok(());
        };
        spawn_socket_reader(reader, generation, self.tx.clone());
        self.log("connected", Some(attempt));

        let replay = self.ever_connected && self.init.delivered;
        self.ever_connected = true;
        let phase = if replay {
            Phase::Replaying {
                deadline: Instant::now() + REPLAY_TIMEOUT,
                init_id: self.init.id.clone().unwrap_or(Value::Null),
            }
        } else {
            Phase::Ready
        };
        self.conn = Some(Connection {
            stream,
            generation,
            phase,
            since: Instant::now(),
            heard_from_daemon: false,
        });

        if replay {
            let frame = self.init.frame.clone().unwrap_or_default();
            if self.write_socket(&frame).is_err() {
                return self.connection_lost("socket_error");
            }
        } else {
            self.flush_queue()?;
        }
        Ok(())
    }

    /// Connect and send the Hello frame — the identity handshake, byte for
    /// byte what the single-shot bridge sent.
    fn open_stream(&self) -> std::io::Result<UnixStream> {
        let stream = UnixStream::connect(&self.config.socket_path)?;
        stream.set_write_timeout(Some(WRITE_TIMEOUT))?;
        let hello = format!(
            "{{\"type\":\"hello\",\"pty_id\":\"{}\"}}\n",
            self.config.pty_id
        );
        (&stream).write_all(hello.as_bytes())?;
        Ok(stream)
    }

    fn schedule_after_failure(&mut self) {
        self.failures = self.failures.saturating_add(1);
        self.schedule(self.failures - 1);
    }

    fn schedule(&mut self, attempt: u32) {
        let delay = self
            .config
            .backoff
            .jittered(attempt, (self.config.jitter)());
        if let Some(observe) = &self.config.on_schedule {
            observe(attempt, delay);
        }
        self.next_attempt = Instant::now() + delay;
    }

    // ── the connection went away ─────────────────────────────────────────────

    fn connection_lost(&mut self, reason: &str) -> Result<(), Exit> {
        let Some(conn) = self.conn.take() else {
            return Ok(());
        };
        let _ = conn.stream.shutdown(Shutdown::Both);
        let attempt = self.failures + 1;
        self.log(reason, Some(attempt));

        // Nobody will ever answer what was sent: say so, by id.
        let mut orphans: Vec<(u64, Value)> = self.in_flight.drain().map(|(_, v)| v).collect();
        orphans.sort_by_key(|(seq, _)| *seq);
        for (_, id) in orphans {
            self.write_client(&lost_error(&id))?;
        }

        let lived = conn.since.elapsed();
        let healthy =
            matches!(conn.phase, Phase::Ready) && (conn.heard_from_daemon || lived >= STABLE_AFTER);
        if healthy {
            self.failures = 0;
            if lived < STABLE_AFTER {
                self.schedule(0);
            } else {
                self.next_attempt = Instant::now();
            }
        } else {
            self.schedule_after_failure();
        }
        Ok(())
    }

    fn check_replay_deadline(&mut self) -> Result<(), Exit> {
        let overdue = matches!(
            &self.conn,
            Some(Connection { phase: Phase::Replaying { deadline, .. }, .. })
                if Instant::now() >= *deadline
        );
        if overdue {
            self.connection_lost("replay_failed")?;
        }
        Ok(())
    }

    // ── client → daemon ──────────────────────────────────────────────────────

    fn on_client_frame(&mut self, frame: Vec<u8>) -> Result<(), Exit> {
        let kind = classify(&frame);
        match &kind {
            Kind::Request { id, method } if method == "initialize" => {
                self.init = Handshake {
                    frame: Some(frame.clone()),
                    id: Some(id.clone()),
                    delivered: false,
                };
            }
            Kind::Notification { method } if method == "notifications/initialized" => {
                self.initialized = Handshake {
                    frame: Some(frame.clone()),
                    id: None,
                    delivered: false,
                };
            }
            _ => {}
        }
        let ready = matches!(
            &self.conn,
            Some(Connection {
                phase: Phase::Ready,
                ..
            })
        );
        if ready {
            self.forward(frame, kind)
        } else {
            self.enqueue(frame, kind)
        }
    }

    /// Hold a frame until there is a ready connection, or refuse it when the
    /// queue is full: a request gets the lost-connection error, a
    /// notification is dropped.
    fn enqueue(&mut self, frame: Vec<u8>, kind: Kind) -> Result<(), Exit> {
        if frame.is_empty() {
            return Ok(());
        }
        let size = frame.len() + 1;
        if self.queue.len() >= QUEUE_MAX_FRAMES || self.queue_bytes + size > QUEUE_MAX_BYTES {
            if let Kind::Request { id, .. } = &kind {
                self.write_client(&lost_error(id))?;
            }
            return Ok(());
        }
        self.queue_bytes += size;
        self.queue.push_back(Queued { frame, kind });
        Ok(())
    }

    /// Send queued frames, in order, until the queue is empty or the
    /// connection goes away again.
    fn flush_queue(&mut self) -> Result<(), Exit> {
        while self.conn.is_some() {
            let Some(Queued { frame, kind }) = self.queue.pop_front() else {
                break;
            };
            self.queue_bytes -= frame.len() + 1;
            self.forward(frame, kind)?;
        }
        Ok(())
    }

    /// Write one client frame to the daemon, noting it as in flight first so a
    /// failed write still errors the request back to the client.
    fn forward(&mut self, frame: Vec<u8>, kind: Kind) -> Result<(), Exit> {
        match &kind {
            Kind::Request { id, method } => {
                self.sent += 1;
                self.in_flight
                    .insert(id.to_string(), (self.sent, id.clone()));
                if method == "initialize" {
                    self.init.delivered = true;
                }
            }
            Kind::Notification { method } if method == "notifications/initialized" => {
                self.initialized.delivered = true;
            }
            Kind::Notification { method } if method == "notifications/cancelled" => {
                // The daemon never answers a cancelled request: stop tracking
                // it so a later drop does not send the client a stray error.
                if let Some(id) = cancelled_request_id(&frame) {
                    self.in_flight.remove(&id.to_string());
                }
            }
            _ => {}
        }
        if self.write_socket(&frame).is_err() {
            return self.connection_lost("socket_error");
        }
        Ok(())
    }

    fn write_socket(&mut self, frame: &[u8]) -> std::io::Result<()> {
        let Some(conn) = &self.conn else {
            return Err(std::io::ErrorKind::NotConnected.into());
        };
        let mut stream = &conn.stream;
        let mut bytes = Vec::with_capacity(frame.len() + 1);
        bytes.extend_from_slice(frame);
        bytes.push(b'\n');
        stream.write_all(&bytes)?;
        stream.flush()
    }

    // ── daemon → client ──────────────────────────────────────────────────────

    fn on_daemon_frame(&mut self, line: Vec<u8>) -> Result<(), Exit> {
        let Some(conn) = self.conn.as_mut() else {
            return Ok(());
        };
        conn.heard_from_daemon = true;

        if let Phase::Replaying { init_id, .. } = &conn.phase {
            let init_id = init_id.clone();
            match serde_json::from_slice::<Value>(&line) {
                Err(_) => return self.connection_lost("replay_failed"),
                Ok(value) => {
                    if value.get("id") == Some(&init_id) && value.get("method").is_none() {
                        if value.get("error").is_some() {
                            self.log("replay_init_error", None);
                        }
                        return self.replay_acknowledged();
                    }
                }
            }
            // Something else the daemon had to say: the client may want it.
            return self.write_client(&line);
        }

        if let Kind::Response { id } = classify(&line) {
            self.in_flight.remove(&id.to_string());
        }
        self.write_client(&line)
    }

    /// The daemon answered the replayed `initialize`: finish the handshake,
    /// tell the client its tools may have changed, then deliver what queued up.
    fn replay_acknowledged(&mut self) -> Result<(), Exit> {
        if self.initialized.delivered {
            let frame = self.initialized.frame.clone().unwrap_or_default();
            if self.write_socket(&frame).is_err() {
                return self.connection_lost("socket_error");
            }
        }
        if let Some(conn) = self.conn.as_mut() {
            conn.phase = Phase::Ready;
        }
        if self.initialized.delivered {
            self.write_client(&json!({
                "jsonrpc": "2.0",
                "method": "notifications/tools/list_changed",
            }))?;
        }
        self.flush_queue()
    }

    // ── client output ────────────────────────────────────────────────────────

    fn write_client<T: ClientFrame + ?Sized>(&mut self, frame: &T) -> Result<(), Exit> {
        let bytes = frame.to_bytes();
        let result = self
            .out
            .write_all(&bytes)
            .and_then(|()| self.out.write_all(b"\n"))
            .and_then(|()| self.out.flush());
        if result.is_err() {
            self.log("stdout_closed", None);
            return Err(Exit(1));
        }
        Ok(())
    }
}

/// What may be written to the client: raw bytes or a JSON value.
trait ClientFrame {
    fn to_bytes(&self) -> Vec<u8>;
}

impl ClientFrame for [u8] {
    fn to_bytes(&self) -> Vec<u8> {
        self.to_vec()
    }
}

impl ClientFrame for Vec<u8> {
    fn to_bytes(&self) -> Vec<u8> {
        self.clone()
    }
}

impl ClientFrame for Value {
    fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }
}

/// `params.requestId` of a `notifications/cancelled` frame (string or number).
fn cancelled_request_id(frame: &[u8]) -> Option<Value> {
    let value: Value = serde_json::from_slice(frame).ok()?;
    value
        .get("params")?
        .get("requestId")
        .filter(|v| v.is_string() || v.is_number())
        .cloned()
}

fn lost_error(id: &Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": LOST_CODE, "message": LOST_MESSAGE },
    })
}
