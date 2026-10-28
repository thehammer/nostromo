//! Behavioural tests for the reconnecting `nostromo-mcp-bridge`.
//!
//! The real bridge binary is spawned as a child (stdin/stdout piped, `HOME`
//! pointed at a tempdir so nothing under the real home is touched) and talks
//! to a fake daemon: a plain `UnixListener` on a temp path that the test
//! drives line by line. No real `claude` and no real daemon are involved.
//!
//! Contract under test (see the PR / plan for the bridge rewrite):
//!   * the bridge never exits while stdin is open; on socket EOF / error /
//!     connect failure it reconnects with jittered exponential backoff;
//!   * every connection starts with the same Hello frame;
//!   * after a RE-connect the saved `initialize` request (and
//!     `notifications/initialized`) are replayed, the replayed response is
//!     swallowed, and the client gets one `notifications/tools/list_changed`;
//!   * a request in flight when the connection drops gets a -32000 error;
//!   * frames sent while disconnected are queued (256 frames / 1 MiB) and
//!     delivered in order after the replay;
//!   * bytes are forwarded unchanged; the log file is content-free, 0600 and
//!     rotated; exit code 0 once stdin closes.

use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, UNIX_EPOCH};

use nostromo::mcp::bridge::{Backoff, BridgeLog, MAX_LOG_BYTES, MAX_LOG_FILES};
use serde_json::{json, Value};
use tempfile::TempDir;

// ── constants ─────────────────────────────────────────────────────────────────

/// Upper bound for anything we wait for. Failures surface well before a CI
/// timeout; passing runs never wait this long.
const WAIT: Duration = Duration::from_secs(10);
/// Window for "nothing more should arrive" checks.
const QUIET: Duration = Duration::from_millis(300);

const PTY: &str = "pty-bridge-test";
const CANARY: &str = "CANARY-7f3a";

const INIT_REQ: &str = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#;
const INITIALIZED: &str = r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
const LOST: &str = "nostromo daemon connection lost; retry";

fn init_resp(marker: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","id":1,"result":{{"protocolVersion":"2024-11-05","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"{marker}","version":"0"}}}}}}"#
    )
}

fn list_changed() -> Value {
    json!({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})
}

fn lost_error(id: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":LOST}})
}

fn ping(id: i64) -> String {
    format!(r#"{{"jsonrpc":"2.0","id":{id},"method":"ping"}}"#)
}

fn ping_resp(id: i64) -> String {
    format!(r#"{{"jsonrpc":"2.0","id":{id},"result":{{}}}}"#)
}

/// A valid JSON-RPC request of exactly `total` bytes (no newline).
fn padded_request(id: i64, total: usize) -> String {
    let head = format!(r#"{{"jsonrpc":"2.0","id":{id},"method":"tools/call","params":{{"pad":""#);
    let tail = r#""}}"#;
    assert!(total > head.len() + tail.len());
    let pad = "x".repeat(total - head.len() - tail.len());
    let frame = format!("{head}{pad}{tail}");
    assert_eq!(frame.len(), total);
    frame
}

fn short_tempdir() -> TempDir {
    // Unix socket paths are limited to ~104 bytes; keep them short.
    tempfile::Builder::new()
        .prefix("mbr")
        .tempdir_in("/tmp")
        .expect("tempdir under /tmp")
}

// ── fake daemon ───────────────────────────────────────────────────────────────

/// One accepted connection, as seen from the daemon side.
struct Conn {
    lines: Receiver<Vec<u8>>,
    writer: Mutex<UnixStream>,
    ctl: UnixStream,
}

impl Conn {
    fn new(stream: UnixStream) -> Conn {
        let reader = stream.try_clone().expect("clone for reader");
        let writer = stream.try_clone().expect("clone for writer");
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        thread::spawn(move || {
            let mut r = BufReader::new(reader);
            loop {
                let mut buf = Vec::new();
                match r.read_until(b'\n', &mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        if buf.last() == Some(&b'\n') {
                            buf.pop();
                        }
                        if tx.send(buf).is_err() {
                            break;
                        }
                    }
                }
            }
            // tx dropped -> receiver sees Disconnected == the peer closed.
        });
        Conn {
            lines: rx,
            writer: Mutex::new(writer),
            ctl: stream,
        }
    }

    /// Next line the bridge sent (without the newline); `None` on timeout or EOF.
    fn recv_line(&self, timeout: Duration) -> Option<Vec<u8>> {
        self.lines.recv_timeout(timeout).ok()
    }

    fn expect_line(&self) -> Vec<u8> {
        match self.lines.recv_timeout(WAIT) {
            Ok(l) => l,
            Err(RecvTimeoutError::Timeout) => panic!("daemon: no line from the bridge in {WAIT:?}"),
            Err(RecvTimeoutError::Disconnected) => {
                panic!("daemon: the bridge closed the connection; expected a line")
            }
        }
    }

    fn expect_json(&self) -> Value {
        let l = self.expect_line();
        serde_json::from_slice(&l)
            .unwrap_or_else(|e| panic!("daemon: not JSON ({e}): {:?}", String::from_utf8_lossy(&l)))
    }

    fn expect_exact(&self, want: &str) {
        let got = self.expect_line();
        assert_eq!(
            String::from_utf8_lossy(&got),
            want,
            "daemon: unexpected frame from the bridge"
        );
    }

    fn expect_hello(&self, pty: &str) {
        let v = self.expect_json();
        assert_eq!(
            v,
            json!({"type":"hello","pty_id":pty}),
            "first frame must be Hello"
        );
    }

    /// Standard replay as seen by the daemon: Hello, the saved initialize
    /// (exact bytes), then -- after we answer it -- the initialized
    /// notification.
    fn serve_replay(&self, pty: &str, init: &str, marker: &str) {
        self.expect_hello(pty);
        self.expect_exact(init);
        self.send_line(&init_resp(marker));
        self.expect_exact(INITIALIZED);
    }

    fn send(&self, bytes: &[u8]) {
        let mut w = self.writer.lock().unwrap();
        let _ = w.write_all(bytes);
        let _ = w.flush();
    }

    fn send_line(&self, line: &str) {
        let mut b = line.as_bytes().to_vec();
        b.push(b'\n');
        self.send(&b);
    }

    fn close(&self) {
        let _ = self.ctl.shutdown(std::net::Shutdown::Both);
    }

    /// True once the bridge has closed its end (draining anything pending).
    fn wait_peer_closed(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(_) => continue,
                Err(RecvTimeoutError::Disconnected) => return true,
                Err(RecvTimeoutError::Timeout) => return false,
            }
        }
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        self.close();
    }
}

/// A Unix-socket "daemon" that hands each accepted connection to the test.
struct FakeDaemon {
    path: PathBuf,
    accepts_tx: Sender<Conn>,
    accepts_rx: Receiver<Conn>,
    stop: Option<Arc<AtomicBool>>,
    thread: Option<JoinHandle<()>>,
}

impl FakeDaemon {
    fn start(path: &Path) -> FakeDaemon {
        let (accepts_tx, accepts_rx) = mpsc::channel();
        let mut d = FakeDaemon {
            path: path.to_path_buf(),
            accepts_tx,
            accepts_rx,
            stop: None,
            thread: None,
        };
        d.listen();
        d
    }

    /// (Re)bind the socket path and start accepting.
    fn listen(&mut self) {
        assert!(self.thread.is_none(), "already listening");
        let _ = fs::remove_file(&self.path);
        let listener = UnixListener::bind(&self.path).expect("bind fake daemon socket");
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stop2 = stop.clone();
        let tx = self.accepts_tx.clone();
        self.thread = Some(thread::spawn(move || {
            while !stop2.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        if tx.send(Conn::new(stream)).is_err() {
                            break;
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(_) => break,
                }
            }
            // listener dropped here: nothing listens any more.
        }));
        self.stop = Some(stop);
    }

    /// Drop the listener and remove the socket file. Existing connections are
    /// untouched (close them with `Conn::close`).
    fn stop_listening(&mut self) {
        if let Some(stop) = self.stop.take() {
            stop.store(true, Ordering::SeqCst);
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        let _ = fs::remove_file(&self.path);
    }

    fn accept(&self) -> Conn {
        self.accepts_rx
            .recv_timeout(WAIT)
            .unwrap_or_else(|_| panic!("the bridge did not connect within {WAIT:?}"))
    }
}

impl Drop for FakeDaemon {
    fn drop(&mut self) {
        self.stop_listening();
    }
}

// ── bridge harness ────────────────────────────────────────────────────────────

struct Bridge {
    child: Child,
    stdin_tx: Option<Sender<Vec<u8>>>,
    out: Receiver<Vec<u8>>,
    home: TempDir,
    pid: u32,
    _writer: JoinHandle<()>,
}

impl Bridge {
    fn spawn(socket: &Path, pty: &str) -> Bridge {
        Bridge::spawn_with(socket, pty, 20, 200)
    }

    fn spawn_with(socket: &Path, pty: &str, min_ms: u64, max_ms: u64) -> Bridge {
        let home = tempfile::tempdir().expect("home tempdir");
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_nostromo-mcp-bridge"));
        cmd.env_clear()
            .env("HOME", home.path())
            .env("NOSTROMO_MCP_SOCKET", socket)
            .env("NOSTROMO_PTY_ID", pty)
            .env("NOSTROMO_MCP_BRIDGE_BACKOFF_MIN_MS", min_ms.to_string())
            .env("NOSTROMO_MCP_BRIDGE_BACKOFF_MAX_MS", max_ms.to_string())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        if let Some(path) = std::env::var_os("PATH") {
            cmd.env("PATH", path);
        }
        let mut child = cmd.spawn().expect("spawn nostromo-mcp-bridge");
        let pid = child.id();

        // Writes go through a thread so a misbehaving bridge that stops
        // reading stdin can never hang the test body.
        let mut stdin: ChildStdin = child.stdin.take().unwrap();
        let (stdin_tx, stdin_rx) = mpsc::channel::<Vec<u8>>();
        let writer = thread::spawn(move || {
            while let Ok(bytes) = stdin_rx.recv() {
                if stdin.write_all(&bytes).is_err() || stdin.flush().is_err() {
                    break;
                }
            }
            // stdin dropped here -> the bridge sees EOF.
        });

        let stdout = child.stdout.take().unwrap();
        let (out_tx, out) = mpsc::channel::<Vec<u8>>();
        thread::spawn(move || {
            let mut r = BufReader::new(stdout);
            loop {
                let mut buf = Vec::new();
                match r.read_until(b'\n', &mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        if out_tx.send(buf).is_err() {
                            break;
                        }
                    }
                }
            }
        });

        Bridge {
            child,
            stdin_tx: Some(stdin_tx),
            out,
            home,
            pid,
            _writer: writer,
        }
    }

    fn send(&self, bytes: &[u8]) {
        if let Some(tx) = &self.stdin_tx {
            let _ = tx.send(bytes.to_vec());
        }
    }

    fn send_line(&self, line: &str) {
        let mut b = line.as_bytes().to_vec();
        b.push(b'\n');
        self.send(&b);
    }

    fn send_json(&self, v: &Value) {
        self.send_line(&v.to_string());
    }

    fn close_stdin(&mut self) {
        self.stdin_tx = None;
    }

    /// Next stdout line from the bridge, newline stripped.
    fn recv(&self, timeout: Duration) -> Option<Vec<u8>> {
        let mut l = self.out.recv_timeout(timeout).ok()?;
        assert_eq!(
            l.last(),
            Some(&b'\n'),
            "bridge stdout frames must end in a newline"
        );
        l.pop();
        Some(l)
    }

    fn expect(&self) -> Vec<u8> {
        self.recv(WAIT)
            .unwrap_or_else(|| panic!("client: no stdout line from the bridge within {WAIT:?}"))
    }

    fn expect_json(&self) -> Value {
        let l = self.expect();
        serde_json::from_slice(&l)
            .unwrap_or_else(|e| panic!("client: not JSON ({e}): {:?}", String::from_utf8_lossy(&l)))
    }

    /// Collect stdout frames until the `result` for `id` arrives; returns all
    /// of them (parsed), the result last.
    fn collect_until_result(&self, id: i64) -> Vec<Value> {
        let mut seen = Vec::new();
        loop {
            let v = self.expect_json();
            let done = v.get("id") == Some(&json!(id)) && v.get("result").is_some();
            seen.push(v);
            if done {
                return seen;
            }
        }
    }

    /// Round-trip a ping through `conn` and return every client-visible frame
    /// up to and including its response. Anything unexpected the bridge sent
    /// to the client earlier shows up in the returned list; anything
    /// unexpected it sent to the daemon fails `expect_exact` here.
    fn fence(&self, conn: &Conn, id: i64) -> Vec<Value> {
        self.send_line(&ping(id));
        conn.expect_exact(&ping(id));
        conn.send_line(&ping_resp(id));
        self.collect_until_result(id)
    }

    fn wait_exit(&mut self, timeout: Duration) -> Option<ExitStatus> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(st) = self.child.try_wait().expect("try_wait") {
                return Some(st);
            }
            if Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn is_running(&mut self) -> bool {
        self.child.try_wait().expect("try_wait").is_none()
    }

    fn log_path(&self) -> PathBuf {
        self.home
            .path()
            .join(".nostromo")
            .join("logs")
            .join(format!("mcp-bridge-{}.log", self.pid))
    }

    fn log(&self) -> String {
        fs::read(self.log_path())
            .map(|b| String::from_utf8_lossy(&b).into_owned())
            .unwrap_or_default()
    }

    fn log_count(&self, needle: &str) -> usize {
        self.log().lines().filter(|l| l.contains(needle)).count()
    }

    /// Wait until the log has at least `n` lines containing `needle`.
    fn wait_log_count(&self, needle: &str, n: usize) {
        let deadline = Instant::now() + WAIT;
        loop {
            if self.log_count(needle) >= n {
                return;
            }
            if Instant::now() >= deadline {
                panic!(
                    "bridge log never reached {n} line(s) with {needle:?}; log was:\n{}",
                    self.log()
                );
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A bridge that has completed a normal first-connection handshake.
struct Session {
    bridge: Bridge,
    daemon: FakeDaemon,
    conn: Conn,
    _dir: TempDir,
}

fn established() -> Session {
    established_with(INIT_REQ)
}

fn established_with(init: &str) -> Session {
    let dir = short_tempdir();
    let sock = dir.path().join("d.sock");
    let daemon = FakeDaemon::start(&sock);
    let bridge = Bridge::spawn(&sock, PTY);
    let conn = daemon.accept();
    conn.expect_hello(PTY);

    bridge.send_line(init);
    conn.expect_exact(init);
    let resp = init_resp("first-connection");
    conn.send_line(&resp);
    assert_eq!(String::from_utf8_lossy(&bridge.expect()), resp);

    bridge.send_line(INITIALIZED);
    conn.expect_exact(INITIALIZED);

    Session {
        bridge,
        daemon,
        conn,
        _dir: dir,
    }
}

fn count_list_changed(frames: &[Value]) -> usize {
    frames.iter().filter(|v| **v == list_changed()).count()
}

// ── BR-1: reconnect ───────────────────────────────────────────────────────────

#[test]
fn first_connection_forwards_client_frames_without_replay_or_list_changed() {
    let s = established();
    // If the bridge had replayed anything or announced a list change on the
    // very first connection, the fence would see it.
    let frames = s.bridge.fence(&s.conn, 50);
    assert_eq!(
        frames,
        vec![serde_json::from_str::<Value>(&ping_resp(50)).unwrap()]
    );
}

#[test]
fn reconnects_after_the_daemon_closes_the_connection_and_the_next_request_is_answered() {
    let s = established();
    s.conn.close();

    let c2 = s.daemon.accept();
    c2.serve_replay(PTY, INIT_REQ, "second-connection");
    assert_eq!(s.bridge.expect_json(), list_changed());

    s.bridge.send_line(&ping(7));
    c2.expect_exact(&ping(7));
    c2.send_line(&ping_resp(7));
    assert_eq!(
        s.bridge.expect_json(),
        serde_json::from_str::<Value>(&ping_resp(7)).unwrap()
    );
}

#[test]
fn reconnects_after_the_listener_disappears_and_is_rebound_later_at_the_same_path() {
    let mut s = established();
    s.daemon.stop_listening();
    s.conn.close();

    // The bridge notices, tries to reconnect, fails, and keeps trying.
    s.bridge.wait_log_count("socket_eof", 1);
    s.bridge.wait_log_count("connect_failed", 2);
    assert!(
        s.bridge.is_running(),
        "bridge must outlive a missing daemon"
    );

    s.daemon.listen();
    let c2 = s.daemon.accept();
    c2.serve_replay(PTY, INIT_REQ, "rebound");
    assert_eq!(s.bridge.expect_json(), list_changed());

    s.bridge.send_line(&ping(8));
    c2.expect_exact(&ping(8));
    c2.send_line(&ping_resp(8));
    assert_eq!(s.bridge.expect_json()["id"], json!(8));
}

#[test]
fn bridge_started_before_the_daemon_connects_when_it_appears_without_duplicating_the_handshake() {
    let dir = short_tempdir();
    let sock = dir.path().join("d.sock");
    let bridge = Bridge::spawn(&sock, PTY);
    bridge.wait_log_count("connect_failed", 1);

    // The client handshakes while nothing is listening: frames are queued.
    bridge.send_line(INIT_REQ);
    let daemon = FakeDaemon::start(&sock);
    let c1 = daemon.accept();
    c1.expect_hello(PTY);
    // This is the FIRST successful connection: the queued initialize is simply
    // delivered once; nothing is replayed in addition.
    c1.expect_exact(INIT_REQ);
    c1.send_line(&init_resp("late-daemon"));
    assert_eq!(
        String::from_utf8_lossy(&bridge.expect()),
        init_resp("late-daemon")
    );
    bridge.send_line(INITIALIZED);
    c1.expect_exact(INITIALIZED);

    let frames = bridge.fence(&c1, 51);
    assert_eq!(
        count_list_changed(&frames),
        0,
        "no list_changed on the first connection: {frames:?}"
    );
    assert_eq!(frames.len(), 1);
}

// ── handshake replay ──────────────────────────────────────────────────────────

#[test]
fn handshake_is_replayed_once_per_reconnect_and_the_replayed_response_is_not_forwarded() {
    let s = established();
    s.conn.close();

    let c2 = s.daemon.accept();
    // serve_replay asserts: Hello, then the saved initialize byte-for-byte
    // (same id), then -- only after we answered it -- the initialized frame.
    c2.serve_replay(PTY, INIT_REQ, "REPLAYED-INIT-MARKER");

    // No further replay traffic: the next thing the daemon sees is our ping.
    let frames = s.bridge.fence(&c2, 60);
    assert_eq!(
        frames.len(),
        2,
        "list_changed + the ping response only: {frames:?}"
    );
    assert_eq!(count_list_changed(&frames), 1);
    for f in &frames {
        assert!(
            !f.to_string().contains("REPLAYED-INIT-MARKER"),
            "the replayed initialize response leaked to the client: {f}"
        );
    }
}

#[test]
fn replay_waits_for_the_initialize_response_before_sending_initialized() {
    let s = established();
    s.conn.close();

    let c2 = s.daemon.accept();
    c2.expect_hello(PTY);
    c2.expect_exact(INIT_REQ);
    // We have not answered yet: initialized must not be sent.
    assert!(
        c2.recv_line(QUIET).is_none(),
        "bridge sent a frame before the initialize response arrived"
    );
    c2.send_line(&init_resp("slow"));
    c2.expect_exact(INITIALIZED);
}

#[test]
fn only_initialize_is_replayed_when_the_client_never_sent_initialized() {
    let dir = short_tempdir();
    let sock = dir.path().join("d.sock");
    let daemon = FakeDaemon::start(&sock);
    let bridge = Bridge::spawn(&sock, PTY);
    let c1 = daemon.accept();
    c1.expect_hello(PTY);
    bridge.send_line(INIT_REQ);
    c1.expect_exact(INIT_REQ);
    c1.send_line(&init_resp("one"));
    bridge.expect();
    // Client has NOT sent notifications/initialized.
    c1.close();

    let c2 = daemon.accept();
    c2.expect_hello(PTY);
    c2.expect_exact(INIT_REQ);
    c2.send_line(&init_resp("two"));

    // The next frame the daemon sees must be our ping, not an initialized
    // notification; and the client must not be told the tool list changed.
    let frames = bridge.fence(&c2, 61);
    assert_eq!(
        count_list_changed(&frames),
        0,
        "list_changed is only owed when the client had initialized: {frames:?}"
    );
}

#[test]
fn tools_list_changed_is_emitted_exactly_once_per_reconnect() {
    let s = established();
    let mut current = s.conn;
    for round in 0..3i64 {
        current.close();
        s.bridge.wait_log_count("socket_eof", (round + 1) as usize);
        let next = s.daemon.accept();
        next.serve_replay(PTY, INIT_REQ, "again");
        let frames = s.bridge.fence(&next, 100 + round);
        assert_eq!(
            count_list_changed(&frames),
            1,
            "round {round}: expected exactly one list_changed, got {frames:?}"
        );
        assert_eq!(
            frames.len(),
            2,
            "round {round}: unexpected extra frames {frames:?}"
        );
        current = next;
    }
}

#[test]
fn hello_is_resent_with_the_same_pty_id_on_every_connection() {
    let s = established(); // asserts Hello on connection 1
    s.conn.close();
    let c2 = s.daemon.accept();
    // serve_replay asserts the Hello is the very first frame.
    c2.serve_replay(PTY, INIT_REQ, "x");
    c2.close();
    let c3 = s.daemon.accept();
    c3.serve_replay(PTY, INIT_REQ, "y");
}

// ── replay failure ────────────────────────────────────────────────────────────

#[test]
fn replay_answered_with_garbage_is_abandoned_and_retried_on_a_new_connection() {
    let mut s = established();
    s.conn.close();

    let c2 = s.daemon.accept();
    c2.expect_hello(PTY);
    c2.expect_exact(INIT_REQ);
    c2.send(b"this is definitely not json\n");
    assert!(
        c2.wait_peer_closed(WAIT),
        "bridge should close a connection whose replay failed"
    );

    let c3 = s.daemon.accept();
    c3.serve_replay(PTY, INIT_REQ, "third-time-lucky");
    assert!(s.bridge.is_running());
    assert!(
        s.bridge.log().contains("replay_failed"),
        "log should record replay_failed:\n{}",
        s.bridge.log()
    );
    let frames = s.bridge.fence(&c3, 70);
    assert_eq!(count_list_changed(&frames), 1, "{frames:?}");
    assert!(
        !frames.iter().any(|f| f.to_string().contains("not json")),
        "garbage must not be forwarded to the client: {frames:?}"
    );
}

#[test]
fn replay_cut_short_by_the_daemon_closing_is_retried_on_a_new_connection() {
    let s = established();
    s.conn.close();

    let c2 = s.daemon.accept();
    c2.expect_hello(PTY);
    c2.expect_exact(INIT_REQ);
    c2.close();

    let c3 = s.daemon.accept();
    c3.serve_replay(PTY, INIT_REQ, "retry");
    let frames = s.bridge.fence(&c3, 71);
    assert_eq!(count_list_changed(&frames), 1, "{frames:?}");
}

// ── BR-2: in-flight requests ──────────────────────────────────────────────────

fn in_flight_request_gets_a_lost_error(id: Value) {
    let s = established();
    let req = json!({"jsonrpc":"2.0","id":id.clone(),"method":"tools/call",
                     "params":{"name":"nostromo.get_self","arguments":{}}});
    s.bridge.send_json(&req);
    assert_eq!(s.conn.expect_json(), req);

    // The daemon dies without answering.
    s.conn.close();

    assert_eq!(
        s.bridge.expect_json(),
        lost_error(id),
        "client must get the -32000 error carrying its own id (same JSON type)"
    );
}

#[test]
fn in_flight_request_with_a_string_id_gets_a_32000_error_when_the_connection_drops() {
    in_flight_request_gets_a_lost_error(json!("req-abc-1"));
}

#[test]
fn in_flight_request_with_an_integer_id_gets_a_32000_error_when_the_connection_drops() {
    in_flight_request_gets_a_lost_error(json!(42));
}

#[test]
fn a_numeric_looking_string_id_stays_a_string_in_the_error() {
    in_flight_request_gets_a_lost_error(json!("42"));
}

#[test]
fn every_unanswered_request_is_errored_but_answered_requests_and_notifications_are_not() {
    let s = established();

    // Answered before the drop.
    s.bridge.send_line(&ping(1));
    s.conn.expect_exact(&ping(1));
    s.conn.send_line(&ping_resp(1));
    assert_eq!(s.bridge.expect_json()["id"], json!(1));

    // A notification (no id) and three requests that will never be answered.
    let note = r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}"#;
    s.bridge.send_line(note);
    s.conn.expect_exact(note);
    for id in [2, 3, 4] {
        s.bridge.send_line(&ping(id));
        s.conn.expect_exact(&ping(id));
    }
    s.conn.close();

    let mut errored: Vec<i64> = Vec::new();
    for _ in 0..3 {
        let v = s.bridge.expect_json();
        assert_eq!(v["error"]["code"], json!(-32000), "{v}");
        assert_eq!(v["error"]["message"], json!(LOST), "{v}");
        errored.push(v["id"].as_i64().expect("integer id preserved"));
    }
    errored.sort();
    assert_eq!(errored, vec![2, 3, 4]);

    // After the reconnect there are no stragglers: only list_changed, then
    // the fence response.
    let c2 = s.daemon.accept();
    c2.serve_replay(PTY, INIT_REQ, "z");
    let frames = s.bridge.fence(&c2, 5);
    assert_eq!(frames.len(), 2, "{frames:?}");
    assert_eq!(count_list_changed(&frames), 1);
}

// ── queueing while disconnected ───────────────────────────────────────────────

#[test]
fn frames_sent_while_disconnected_are_delivered_in_order_after_the_replay() {
    let mut s = established();
    s.daemon.stop_listening();
    s.conn.close();
    s.bridge.wait_log_count("connect_failed", 1);

    let note = r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}"#;
    s.bridge.send_line(&ping(10));
    s.bridge.send_line(note);
    s.bridge.send_line(&ping(11));
    // Queued, not errored: nothing comes back while the daemon is away.
    assert!(
        s.bridge.recv(QUIET).is_none(),
        "queued frames must not be answered or errored while disconnected"
    );

    s.daemon.listen();
    let c2 = s.daemon.accept();
    // Hello, initialize, initialized come first...
    c2.serve_replay(PTY, INIT_REQ, "q");
    // ...then the queued frames, in the order the client sent them.
    c2.expect_exact(&ping(10));
    c2.expect_exact(note);
    c2.expect_exact(&ping(11));
    c2.send_line(&ping_resp(10));
    c2.send_line(&ping_resp(11));

    let mut got = Vec::new();
    for _ in 0..3 {
        got.push(s.bridge.expect_json());
    }
    assert_eq!(count_list_changed(&got), 1, "{got:?}");
    let ids: Vec<&Value> = got.iter().filter_map(|v| v.get("id")).collect();
    assert_eq!(ids, vec![&json!(10), &json!(11)]);
}

#[test]
fn frames_sent_while_the_replay_is_in_progress_wait_for_it_to_finish() {
    let s = established();
    s.conn.close();

    let c2 = s.daemon.accept();
    c2.expect_hello(PTY);
    c2.expect_exact(INIT_REQ);

    // The client talks while the replay is still waiting on the daemon.
    s.bridge.send_line(&ping(20));
    assert!(
        c2.recv_line(QUIET).is_none(),
        "client frames must not overtake the handshake replay"
    );

    c2.send_line(&init_resp("slow"));
    c2.expect_exact(INITIALIZED);
    c2.expect_exact(&ping(20));
}

#[test]
fn queue_holds_at_most_256_frames_and_errors_requests_beyond_that_while_dropping_notifications() {
    let mut s = established();
    s.daemon.stop_listening();
    s.conn.close();
    s.bridge.wait_log_count("connect_failed", 1);

    for id in 1000..1256 {
        s.bridge.send_line(&ping(id));
    }
    // Past the bound: notifications are silently dropped...
    for _ in 0..3 {
        s.bridge
            .send_line(r#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"n":1}}"#);
    }
    // ...and requests are refused immediately, by id.
    s.bridge.send_line(&ping(2000));
    s.bridge.send_line(&ping(2001));

    assert_eq!(s.bridge.expect_json(), lost_error(json!(2000)));
    assert_eq!(s.bridge.expect_json(), lost_error(json!(2001)));
    assert!(
        s.bridge.recv(QUIET).is_none(),
        "only the two over-bound requests may be answered while disconnected"
    );

    s.daemon.listen();
    let c2 = s.daemon.accept();
    c2.serve_replay(PTY, INIT_REQ, "q");
    for id in 1000..1256 {
        c2.expect_exact(&ping(id));
    }
    assert!(
        c2.recv_line(QUIET).is_none(),
        "dropped notifications / refused requests must never reach the daemon"
    );
}

#[test]
fn queue_holds_at_most_one_mebibyte_and_errors_requests_beyond_that() {
    let mut s = established();
    s.daemon.stop_listening();
    s.conn.close();
    s.bridge.wait_log_count("connect_failed", 1);

    // 10 x 100,000 bytes fits under 1 MiB (1,048,576); the 11th does not.
    for id in 1..=12 {
        s.bridge.send_line(&padded_request(id, 100_000));
    }
    assert_eq!(s.bridge.expect_json(), lost_error(json!(11)));
    assert_eq!(s.bridge.expect_json(), lost_error(json!(12)));
    assert!(s.bridge.recv(QUIET).is_none());

    s.daemon.listen();
    let c2 = s.daemon.accept();
    c2.serve_replay(PTY, INIT_REQ, "q");
    for id in 1..=10 {
        let line = c2.expect_line();
        assert_eq!(line.len(), 100_000, "frame {id} must be delivered whole");
        let v: Value = serde_json::from_slice(&line).unwrap();
        assert_eq!(v["id"], json!(id), "queued frames keep their order");
    }
    assert!(c2.recv_line(QUIET).is_none());
}

#[test]
fn a_single_frame_over_one_mebibyte_is_refused_while_disconnected_and_later_frames_still_queue() {
    let mut s = established();
    s.daemon.stop_listening();
    s.conn.close();
    s.bridge.wait_log_count("connect_failed", 1);

    s.bridge.send_line(&padded_request(77, 1_048_576 + 1_000));
    assert_eq!(s.bridge.expect_json(), lost_error(json!(77)));

    s.bridge.send_line(&ping(78));
    assert!(s.bridge.recv(QUIET).is_none());

    s.daemon.listen();
    let c2 = s.daemon.accept();
    c2.serve_replay(PTY, INIT_REQ, "q");
    // Had the huge frame been queued it would arrive first.
    c2.expect_exact(&ping(78));
    assert!(c2.recv_line(QUIET).is_none());
}

// ── lifetime ──────────────────────────────────────────────────────────────────

#[test]
fn bridge_stays_alive_while_the_daemon_is_gone_and_exits_zero_only_when_stdin_closes() {
    let mut s = established();
    s.daemon.stop_listening();
    s.conn.close();

    // Several failed reconnect attempts later it is still running.
    s.bridge.wait_log_count("connect_failed", 4);
    assert!(
        s.bridge.is_running(),
        "bridge must not give up on the daemon"
    );

    s.bridge.close_stdin();
    let status = s
        .bridge
        .wait_exit(Duration::from_secs(3))
        .expect("bridge should exit once stdin closes");
    assert_eq!(status.code(), Some(0));
}

#[test]
fn stdin_closing_while_backing_off_exits_promptly_with_code_zero() {
    let dir = short_tempdir();
    let sock = dir.path().join("absent.sock");
    // A long backoff: if the bridge only noticed stdin EOF after sleeping it
    // out, this test would take ~5 s.
    let mut bridge = Bridge::spawn_with(&sock, PTY, 5_000, 5_000);
    bridge.wait_log_count("connect_failed", 1);

    let t = Instant::now();
    bridge.close_stdin();
    let status = bridge
        .wait_exit(Duration::from_millis(2_000))
        .expect("bridge should exit promptly when stdin closes during backoff");
    assert_eq!(status.code(), Some(0));
    assert!(t.elapsed() < Duration::from_millis(2_000));
}

#[test]
fn stdin_closing_while_connected_exits_with_code_zero() {
    let mut s = established();
    s.bridge.close_stdin();
    let status = s
        .bridge
        .wait_exit(Duration::from_secs(3))
        .expect("bridge should exit once stdin closes");
    assert_eq!(status.code(), Some(0));
}

// ── byte transparency ─────────────────────────────────────────────────────────

#[test]
fn non_utf8_and_non_json_lines_pass_through_unchanged_in_both_directions() {
    let s = established();

    let up1: &[u8] = b"\xff\xfe\x00 not json \x80\xc3\x28";
    let up2: &[u8] = b"plain text, not a frame";
    for l in [up1, up2] {
        let mut b = l.to_vec();
        b.push(b'\n');
        s.bridge.send(&b);
        assert_eq!(
            s.conn.expect_line(),
            l,
            "client->daemon bytes must be unchanged"
        );
    }

    let down1: &[u8] = b"\xc3\x28 bad utf8 \xff";
    let down2: &[u8] = br#"{"truncated":"#;
    for l in [down1, down2] {
        let mut b = l.to_vec();
        b.push(b'\n');
        s.conn.send(&b);
        assert_eq!(
            s.bridge.expect(),
            l,
            "daemon->client bytes must be unchanged"
        );
    }

    // Still alive and well.
    assert!(!s.bridge.fence(&s.conn, 90).is_empty());
}

#[test]
fn a_frame_split_across_several_stdin_writes_reaches_the_daemon_whole() {
    let s = established();
    s.bridge.send(br#"{"jsonrpc":"2.0","id":91,"#);
    thread::sleep(Duration::from_millis(50)); // let the first chunk land on its own
    s.bridge.send(br#""method":"ping"}"#);
    s.bridge.send(b"\n");
    s.conn
        .expect_exact(r#"{"jsonrpc":"2.0","id":91,"method":"ping"}"#);
}

// ── log file ──────────────────────────────────────────────────────────────────

fn mode_of(p: &Path) -> u32 {
    fs::metadata(p).unwrap().permissions().mode() & 0o777
}

#[test]
fn log_is_mode_0600_names_the_pty_and_reasons_and_never_contains_frame_contents() {
    let init = format!(
        r#"{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"protocolVersion":"2024-11-05","capabilities":{{}},"clientInfo":{{"name":"{CANARY}-init","version":"0"}}}}}}"#
    );
    let mut s = established_with(&init);

    // A request carrying the canary in its params, answered by a response
    // carrying it too.
    let req = json!({"jsonrpc":"2.0","id":31,"method":"tools/call",
                     "params":{"name":"x","arguments":{"q":CANARY}}});
    s.bridge.send_json(&req);
    s.conn.expect_json();
    s.conn.send_line(&format!(
        r#"{{"jsonrpc":"2.0","id":31,"result":{{"text":"{CANARY}"}}}}"#
    ));
    assert!(String::from_utf8_lossy(&s.bridge.expect()).contains(CANARY));

    // Another one is in flight when the daemon drops.
    let req2 = json!({"jsonrpc":"2.0","id":32,"method":"tools/call",
                      "params":{"name":"x","arguments":{"q":CANARY}}});
    s.bridge.send_json(&req2);
    s.conn.expect_json();
    s.conn.close();
    let err = s.bridge.expect_json();
    assert_eq!(err["error"]["code"], json!(-32000));

    // Reconnect (replays the canary-bearing initialize), then exit cleanly.
    let c2 = s.daemon.accept();
    c2.serve_replay(PTY, &init, "m");
    s.bridge.fence(&c2, 33);
    s.bridge.close_stdin();
    let status = s.bridge.wait_exit(Duration::from_secs(3)).expect("exit");
    assert_eq!(status.code(), Some(0));

    let path = s.bridge.log_path();
    assert!(path.exists(), "expected a log at {path:?}");
    assert_eq!(mode_of(&path), 0o600, "log must be private");

    let log = s.bridge.log();
    assert!(!log.contains(CANARY), "log leaked frame content:\n{log}");
    assert!(
        log.lines()
            .any(|l| l.contains("socket_eof") && l.contains(PTY)),
        "expected a socket_eof line naming the pty:\n{log}"
    );
    assert!(
        log.lines()
            .any(|l| l.contains("stdin_closed") && l.contains(PTY)),
        "expected a stdin_closed line naming the pty:\n{log}"
    );
}

#[test]
fn log_records_connect_failed_with_the_pty_id_when_the_socket_does_not_exist() {
    let dir = short_tempdir();
    let sock = dir.path().join("nope.sock");
    let mut bridge = Bridge::spawn(&sock, PTY);
    bridge.wait_log_count("connect_failed", 2);

    let path = bridge.log_path();
    assert_eq!(mode_of(&path), 0o600);
    assert!(bridge
        .log()
        .lines()
        .any(|l| l.contains("connect_failed") && l.contains(PTY)));

    bridge.close_stdin();
    assert_eq!(
        bridge.wait_exit(Duration::from_secs(3)).unwrap().code(),
        Some(0)
    );
    assert!(bridge.log().contains("stdin_closed"));
}

// ── observed backoff ──────────────────────────────────────────────────────────

fn mean_ms(gaps: &[Duration]) -> f64 {
    gaps.iter().map(|g| g.as_secs_f64() * 1000.0).sum::<f64>() / gaps.len() as f64
}

/// Loose shape check for 7 gaps produced with min=50ms, max=400ms: nominal
/// delays 50,100,200,400,400,400,400 jittered to 50-100%.
fn assert_backoff_shape(gaps: &[Duration]) {
    assert_eq!(gaps.len(), 7);
    let early = mean_ms(&gaps[0..2]); // nominal 50, 100 -> 25..100 ms
    let late = mean_ms(&gaps[4..7]); // nominal 400 -> 200..400 ms
    assert!(
        late >= early * 2.0,
        "delays must grow: early mean {early:.0} ms, late mean {late:.0} ms, gaps {gaps:?}"
    );
    for g in &gaps[4..7] {
        assert!(
            *g >= Duration::from_millis(150),
            "a capped-out gap should be near the max, got {g:?} (gaps {gaps:?})"
        );
    }
    for g in gaps {
        assert!(
            *g <= Duration::from_millis(400 + 600),
            "gap {g:?} exceeds the cap by far too much (gaps {gaps:?})"
        );
    }
}

#[test]
fn connect_failures_back_off_exponentially_up_to_the_configured_max() {
    let dir = short_tempdir();
    let sock = dir.path().join("never.sock");
    let bridge = Bridge::spawn_with(&sock, PTY, 50, 400);

    let mut stamps: Vec<Instant> = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(30);
    while stamps.len() < 8 {
        assert!(
            Instant::now() < deadline,
            "too few connect attempts; log:\n{}",
            bridge.log()
        );
        let n = bridge.log_count("connect_failed");
        while stamps.len() < n && stamps.len() < 8 {
            stamps.push(Instant::now());
        }
        thread::sleep(Duration::from_millis(2));
    }
    let gaps: Vec<Duration> = stamps.windows(2).map(|w| w[1] - w[0]).collect();
    assert_backoff_shape(&gaps);
}

#[test]
fn repeated_replay_failures_back_off_exponentially_up_to_the_configured_max() {
    let dir = short_tempdir();
    let sock = dir.path().join("d.sock");
    let daemon = FakeDaemon::start(&sock);
    let bridge = Bridge::spawn_with(&sock, PTY, 50, 400);

    let c1 = daemon.accept();
    c1.expect_hello(PTY);
    bridge.send_line(INIT_REQ);
    c1.expect_exact(INIT_REQ);
    c1.send_line(&init_resp("one"));
    bridge.expect();
    c1.close();

    // From now on every replay attempt is cut short by the daemon. Attempts
    // keep coming, each after a longer delay.
    let mut stamps: Vec<Instant> = Vec::new();
    for _ in 0..8 {
        let c = daemon.accept();
        stamps.push(Instant::now());
        c.expect_hello(PTY);
        c.expect_exact(INIT_REQ);
        c.close();
    }
    let gaps: Vec<Duration> = stamps.windows(2).map(|w| w[1] - w[0]).collect();
    assert_backoff_shape(&gaps);
}

// ── Backoff (library API) ─────────────────────────────────────────────────────

fn approx(a: Duration, b: Duration) -> bool {
    (a.as_secs_f64() - b.as_secs_f64()).abs() < 1e-6
}

#[test]
fn backoff_starts_at_min_doubles_each_attempt_and_stops_at_max() {
    let b = Backoff::new(Duration::from_millis(100), Duration::from_secs(5));
    let want_ms = [100u64, 200, 400, 800, 1600, 3200, 5000, 5000, 5000];
    for (attempt, ms) in want_ms.iter().enumerate() {
        assert_eq!(
            b.nominal(attempt as u32),
            Duration::from_millis(*ms),
            "attempt {attempt}"
        );
    }
}

#[test]
fn backoff_does_not_overflow_for_huge_attempt_numbers() {
    let b = Backoff::new(Duration::from_millis(100), Duration::from_secs(5));
    for attempt in [31, 32, 63, 64, 65, 1_000, u32::MAX - 1, u32::MAX] {
        assert_eq!(
            b.nominal(attempt),
            Duration::from_secs(5),
            "attempt {attempt}"
        );
        assert!(b.jittered(attempt, 0.999) <= Duration::from_secs(5));
    }
}

#[test]
fn backoff_with_min_equal_to_max_is_constant() {
    let b = Backoff::new(Duration::from_millis(250), Duration::from_millis(250));
    for attempt in [0, 1, 5, u32::MAX] {
        assert_eq!(b.nominal(attempt), Duration::from_millis(250));
    }
}

#[test]
fn backoff_jitter_scales_the_nominal_delay_between_half_and_full() {
    let b = Backoff::new(Duration::from_millis(100), Duration::from_secs(5));
    // unit 0.0 -> 50%, 0.5 -> 75%, approaching 1.0 -> 100% (exclusive).
    assert!(approx(b.jittered(2, 0.0), Duration::from_millis(200)));
    assert!(approx(b.jittered(2, 0.5), Duration::from_millis(300)));
    let almost = b.jittered(2, 0.999_999);
    assert!(almost < Duration::from_millis(400) + Duration::from_micros(1));
    assert!(almost > Duration::from_millis(399));
}

#[test]
fn backoff_jittered_delay_is_always_within_half_to_full_nominal_and_never_over_max() {
    let min = Duration::from_millis(20);
    let max = Duration::from_millis(200);
    let b = Backoff::new(min, max);
    for attempt in (0..40).chain([u32::MAX]) {
        for step in 0..100 {
            let unit = step as f64 / 100.0;
            let j = b.jittered(attempt, unit);
            let nominal = b.nominal(attempt);
            assert!(
                j.as_secs_f64() >= nominal.as_secs_f64() * 0.5 - 1e-9,
                "{attempt} {unit}"
            );
            assert!(
                j.as_secs_f64() <= nominal.as_secs_f64() + 1e-9,
                "{attempt} {unit}"
            );
            assert!(j <= max);
        }
    }
}

// ── BridgeLog (library API) ───────────────────────────────────────────────────

#[test]
fn log_limits_are_twenty_files_and_256_kib() {
    assert_eq!(MAX_LOG_FILES, 20);
    assert_eq!(MAX_LOG_BYTES, 256 * 1024);
}

#[test]
fn opening_a_log_creates_the_directory_and_a_private_pid_named_file() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("a").join("b").join("logs");
    let mut log = BridgeLog::open(&dir, 4242).expect("open");
    log.line("pty-1", "socket_eof", Some(3));
    drop(log);

    let file = dir.join("mcp-bridge-4242.log");
    assert!(file.exists());
    assert_eq!(mode_of(&file), 0o600);
    let text = fs::read_to_string(&file).unwrap();
    assert!(
        text.contains("pty-1") && text.contains("socket_eof"),
        "{text}"
    );
    assert!(text.ends_with('\n'), "each event is one line");
}

#[test]
fn opening_a_log_keeps_only_the_twenty_newest_bridge_logs_including_its_own() {
    let dir = tempfile::tempdir().unwrap();
    for i in 0..25u64 {
        let p = dir.path().join(format!("mcp-bridge-{}.log", 1000 + i));
        fs::write(&p, "old\n").unwrap();
        OpenOptions::new()
            .write(true)
            .open(&p)
            .unwrap()
            .set_modified(UNIX_EPOCH + Duration::from_secs(1_000_000 + i * 10))
            .unwrap();
    }
    // Neither of these matches `mcp-bridge-*.log`: they must survive.
    fs::write(dir.path().join("notes.txt"), "keep").unwrap();
    fs::write(dir.path().join("other.log"), "keep").unwrap();

    let _log = BridgeLog::open(dir.path(), 99).expect("open");

    let mut bridge_logs: Vec<String> = fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("mcp-bridge-") && n.ends_with(".log"))
        .collect();
    bridge_logs.sort();
    assert_eq!(bridge_logs.len(), MAX_LOG_FILES, "{bridge_logs:?}");
    assert!(
        bridge_logs.contains(&"mcp-bridge-99.log".to_string()),
        "own file must survive"
    );
    // 26 files, keep 20 -> the 6 oldest (pids 1000..=1005) are gone.
    for pid in 1000..=1005 {
        assert!(
            !bridge_logs.contains(&format!("mcp-bridge-{pid}.log")),
            "oldest log {pid} should have been pruned: {bridge_logs:?}"
        );
    }
    for pid in 1006..=1024 {
        assert!(
            bridge_logs.contains(&format!("mcp-bridge-{pid}.log")),
            "newer log {pid} must be kept: {bridge_logs:?}"
        );
    }
    assert!(dir.path().join("notes.txt").exists());
    assert!(dir.path().join("other.log").exists());
}

#[test]
fn a_log_file_never_grows_beyond_the_cap_and_keeps_the_newest_whole_lines() {
    let dir = tempfile::tempdir().unwrap();
    let mut log = BridgeLog::open(dir.path(), 7).unwrap();
    let file = dir.path().join("mcp-bridge-7.log");

    const BASE: u32 = 9_000_000;
    // ~60 bytes per line * 12,000 lines is well over 256 KiB.
    for i in 0..12_000u32 {
        log.line("pty-cap", "socket_eof", Some(BASE + i));
        if i % 500 == 0 {
            let len = fs::metadata(&file).unwrap().len();
            assert!(len <= MAX_LOG_BYTES, "log grew to {len} bytes at line {i}");
        }
    }
    drop(log);

    let len = fs::metadata(&file).unwrap().len();
    assert!(len <= MAX_LOG_BYTES, "log is {len} bytes");
    assert_eq!(mode_of(&file), 0o600, "mode must survive trimming");

    let text = fs::read_to_string(&file).unwrap();
    assert!(text.ends_with('\n'));
    assert!(
        text.contains(&(BASE + 11_999).to_string()),
        "newest line must be kept"
    );
    assert!(
        !text.contains(&BASE.to_string()),
        "oldest line must have been dropped"
    );
    for l in text.lines() {
        assert!(
            l.contains("pty-cap") && l.contains("socket_eof"),
            "torn line: {l:?}"
        );
    }
}
