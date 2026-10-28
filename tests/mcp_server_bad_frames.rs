//! Daemon-side hardening of the MCP socket: bad frames never end a connection,
//! and the server tracks how many bridge connections each PTY has.
//!
//! Each test binds a real `McpServer` on a temp socket and talks to it over a
//! real Unix stream, so only wire behaviour is asserted.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime};

use nostromo::mcp::server::MAX_FRAME_BYTES;
use nostromo::mcp::{BridgeRegistry, McpServer, McpSharedState, PtyIdentity, ViewMeta};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::time::{sleep, timeout};

const STEP: Duration = Duration::from_secs(10);
const PTY: &str = "test-pty-id";

// ── captured tracing output (process-global, installed once) ─────────────────

#[derive(Clone, Default)]
struct LogBuf(Arc<Mutex<Vec<u8>>>);

impl io::Write for LogBuf {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl LogBuf {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

/// Install (once) a global INFO-level subscriber that records into a buffer.
/// Global rather than `set_default` so output from the server's spawned tasks
/// is captured whichever runtime thread runs them.
fn captured_logs() -> &'static LogBuf {
    static LOGS: OnceLock<LogBuf> = OnceLock::new();
    LOGS.get_or_init(|| {
        let buf = LogBuf::default();
        let sink = buf.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::INFO)
            .with_ansi(false)
            .with_writer(move || sink.clone())
            .finish();
        tracing::subscriber::set_global_default(subscriber)
            .expect("no other global tracing subscriber in this test binary");
        buf
    })
}

// ── server + client helpers ───────────────────────────────────────────────────

struct Harness {
    _dir: TempDir,
    _server: McpServer,
    state: Arc<McpSharedState>,
    path: PathBuf,
}

async fn start() -> Harness {
    captured_logs();
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("mcp.sock");

    let state = Arc::new(McpSharedState::for_test());
    state.views_meta.write().await.push(ViewMeta {
        id: "perri",
        title: "Perri".to_string(),
        pane_ids: vec!["pr_queue"],
    });
    state
        .register_pty(
            PTY.to_string(),
            PtyIdentity {
                view_id: "perri",
                session_id: "test-session-id".to_string(),
                spawned_at: SystemTime::now(),
            },
        )
        .await;

    let server = McpServer::bind(path.clone(), (*state).clone())
        .await
        .expect("server should bind");
    Harness {
        _dir: dir,
        _server: server,
        state,
        path,
    }
}

struct Client {
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
}

impl Client {
    /// Connect and send `hello` verbatim (callers include the newline).
    async fn connect_raw(path: &Path, hello: &[u8]) -> Client {
        let stream = UnixStream::connect(path).await.unwrap();
        let (r, w) = stream.into_split();
        let mut c = Client {
            reader: BufReader::new(r),
            writer: w,
        };
        c.send(hello).await;
        c
    }

    async fn connect_as(path: &Path, pty: &str) -> Client {
        let hello = format!("{{\"type\":\"hello\",\"pty_id\":\"{pty}\"}}\n");
        Client::connect_raw(path, hello.as_bytes()).await
    }

    async fn send(&mut self, bytes: &[u8]) {
        timeout(STEP, self.writer.write_all(bytes))
            .await
            .expect("write timed out: the server stopped reading")
            .expect("write failed: the server closed the connection");
    }

    async fn send_json(&mut self, v: &Value) {
        let mut b = serde_json::to_vec(v).unwrap();
        b.push(b'\n');
        self.send(&b).await;
    }

    /// Next reply frame; panics with a clear message if the server hung up.
    async fn recv(&mut self) -> Value {
        let mut buf = Vec::new();
        let n = timeout(STEP, self.reader.read_until(b'\n', &mut buf))
            .await
            .expect("timed out waiting for a reply")
            .expect("read failed");
        assert!(
            n > 0,
            "the server closed the connection; it should have stayed open"
        );
        serde_json::from_slice(&buf).unwrap_or_else(|e| {
            panic!(
                "reply is not JSON ({e}): {:?}",
                String::from_utf8_lossy(&buf)
            )
        })
    }

    async fn expect_ping_works(&mut self, id: i64) {
        self.send_json(&json!({"jsonrpc":"2.0","id":id,"method":"ping"}))
            .await;
        let r = self.recv().await;
        assert_eq!(r, json!({"jsonrpc":"2.0","id":id,"result":{}}));
    }

    async fn get_self(&mut self, id: i64) -> Value {
        self.send_json(&json!({
            "jsonrpc":"2.0","id":id,"method":"tools/call",
            "params":{"name":"nostromo.get_self","arguments":{}}
        }))
        .await;
        let r = self.recv().await;
        assert!(r.get("error").is_none(), "get_self errored: {r}");
        let text = r["result"]["content"][0]["text"]
            .as_str()
            .expect("text content");
        serde_json::from_str(text).expect("get_self text is JSON")
    }
}

fn assert_error(reply: &Value, code: i64) {
    assert_eq!(reply["jsonrpc"], json!("2.0"), "{reply}");
    assert_eq!(
        reply["id"],
        Value::Null,
        "frame-level errors carry a null id: {reply}"
    );
    assert_eq!(reply["error"]["code"], json!(code), "{reply}");
}

/// A syntactically valid `ping` request of exactly `total` bytes.
fn padded_ping(id: i64, total: usize) -> Vec<u8> {
    let head = format!(r#"{{"jsonrpc":"2.0","id":{id},"method":"ping","params":{{"pad":""#);
    let tail = r#""}}"#;
    let pad = "a".repeat(total - head.len() - tail.len());
    format!("{head}{pad}{tail}").into_bytes()
}

async fn eventually<F: FnMut() -> bool>(what: &str, mut f: F) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    loop {
        if f() {
            return;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for: {what}"
        );
        sleep(Duration::from_millis(10)).await;
    }
}

// ── bad frames never end the connection ───────────────────────────────────────

#[tokio::test]
async fn a_non_utf8_frame_gets_a_parse_error_and_the_connection_keeps_working() {
    let h = start().await;
    let mut c = Client::connect_as(&h.path, PTY).await;

    c.send(b"\xff\xfe{\"jsonrpc\"\xc3\x28\n").await;
    assert_error(&c.recv().await, -32700);

    c.expect_ping_works(1).await;
}

#[tokio::test]
async fn malformed_json_gets_a_parse_error_and_the_connection_keeps_working() {
    let h = start().await;
    let mut c = Client::connect_as(&h.path, PTY).await;

    c.send(b"{\"jsonrpc\":\"2.0\",\"id\":1,\n").await;
    assert_error(&c.recv().await, -32700);

    c.expect_ping_works(2).await;
}

#[tokio::test]
async fn valid_json_that_is_not_a_request_object_gets_invalid_request() {
    let h = start().await;
    let mut c = Client::connect_as(&h.path, PTY).await;

    for (n, frame) in [&b"[1,2]\n"[..], b"42\n", b"\"just a string\"\n"]
        .into_iter()
        .enumerate()
    {
        c.send(frame).await;
        assert_error(&c.recv().await, -32600);
        c.expect_ping_works(n as i64 + 1).await;
    }
}

#[tokio::test]
async fn an_over_long_frame_is_refused_not_served_and_the_next_request_is_answered() {
    let h = start().await;
    let mut c = Client::connect_as(&h.path, PTY).await;

    // A *valid* ping, but over the cap: it must be refused rather than answered
    // (a reply carrying id 5 would mean the whole frame was buffered and served).
    let mut big = padded_ping(5, MAX_FRAME_BYTES + 10);
    big.push(b'\n');
    c.send(&big).await;
    assert_error(&c.recv().await, -32600);

    c.expect_ping_works(6).await;
}

#[tokio::test]
async fn a_frame_several_times_the_cap_gets_a_single_error_and_the_next_request_is_answered() {
    let h = start().await;
    let mut c = Client::connect_as(&h.path, PTY).await;

    let mut huge = vec![b'z'; MAX_FRAME_BYTES * 3];
    huge.push(b'\n');
    c.send(&huge).await;
    assert_error(&c.recv().await, -32600);

    // If the tail of the giant frame had been parsed as further frames there
    // would be extra replies queued ahead of this one.
    c.expect_ping_works(1).await;
}

#[tokio::test]
async fn a_frame_just_under_the_cap_is_still_served() {
    let h = start().await;
    let mut c = Client::connect_as(&h.path, PTY).await;

    let mut near = padded_ping(9, MAX_FRAME_BYTES - 100);
    near.push(b'\n');
    c.send(&near).await;
    assert_eq!(c.recv().await, json!({"jsonrpc":"2.0","id":9,"result":{}}));
}

#[tokio::test]
async fn several_bad_frames_in_a_row_each_get_an_error_and_the_connection_survives() {
    let h = start().await;
    let mut c = Client::connect_as(&h.path, PTY).await;

    let mut burst: Vec<u8> = Vec::new();
    burst.extend_from_slice(b"\xff\xfe\xfd\n"); // non-UTF-8
    burst.extend_from_slice(b"{not json\n"); // malformed
    burst.extend_from_slice(b"[1]\n"); // not a request object
    burst.extend_from_slice(&vec![b'q'; MAX_FRAME_BYTES + 10]); // over-long
    burst.push(b'\n');
    burst.extend_from_slice(b"}}}\n"); // malformed again
    c.send(&burst).await;

    for code in [-32700, -32700, -32600, -32600, -32700] {
        assert_error(&c.recv().await, code);
    }
    c.expect_ping_works(1).await;
}

#[tokio::test]
async fn bad_frames_between_pipelined_valid_frames_do_not_disturb_their_neighbours() {
    let h = start().await;
    let mut c = Client::connect_as(&h.path, PTY).await;

    // All in one write.
    let mut batch: Vec<u8> = Vec::new();
    batch.extend_from_slice(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n");
    batch.extend_from_slice(b"\xff\xfe\n");
    batch.extend_from_slice(b"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n");
    batch.extend_from_slice(b"{broken\n");
    batch.extend_from_slice(
        b"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":{}}\n",
    );
    c.send(&batch).await;

    assert_eq!(c.recv().await, json!({"jsonrpc":"2.0","id":1,"result":{}}));
    assert_error(&c.recv().await, -32700);
    assert_eq!(c.recv().await, json!({"jsonrpc":"2.0","id":2,"result":{}}));
    assert_error(&c.recv().await, -32700);
    let list = c.recv().await;
    assert_eq!(list["id"], json!(3));
    assert!(list["result"]["tools"].is_array(), "{list}");
}

// ── a bad Hello is "unidentified", not fatal ──────────────────────────────────

async fn assert_unidentified(c: &mut Client) {
    let info = c.get_self(1).await;
    assert_eq!(info["error"], json!("unidentified_caller"), "{info}");
}

#[tokio::test]
async fn a_non_utf8_hello_leaves_the_connection_open_as_an_unidentified_caller() {
    let h = start().await;
    let mut c = Client::connect_raw(&h.path, b"\xff\xfe\xfd\n").await;

    // Hello is not a JSON-RPC frame: no reply is owed for it, so the first
    // thing we read is the answer to our own request.
    assert_unidentified(&mut c).await;
}

#[tokio::test]
async fn an_over_long_hello_leaves_the_connection_open_as_an_unidentified_caller() {
    let h = start().await;
    let mut hello = vec![b'x'; MAX_FRAME_BYTES + 10];
    hello.push(b'\n');
    let mut c = Client::connect_raw(&h.path, &hello).await;

    assert_unidentified(&mut c).await;
}

// ── connection tracking ───────────────────────────────────────────────────────

#[test]
fn registry_counts_live_connections_and_reports_transitions() {
    let r = BridgeRegistry::default();

    assert_eq!(r.connected("p"), None, "never seen");
    assert_eq!(r.live("p"), 0);
    assert_eq!(r.reconnects("p"), 0);

    assert!(r.open("p"), "first open takes live 0 -> 1");
    assert_eq!(r.live("p"), 1);
    assert_eq!(r.connected("p"), Some(true));
    assert_eq!(r.reconnects("p"), 0);

    assert!(!r.open("p"), "second open is 1 -> 2");
    assert_eq!(r.live("p"), 2);

    assert!(!r.close("p"), "2 -> 1");
    assert_eq!(r.live("p"), 1);
    assert_eq!(r.connected("p"), Some(true));

    assert!(r.close("p"), "1 -> 0");
    assert_eq!(r.live("p"), 0);
    assert_eq!(
        r.connected("p"),
        Some(false),
        "seen before, now disconnected"
    );

    assert!(r.open("p"), "0 -> 1 again");
    assert_eq!(r.connected("p"), Some(true));
    assert_eq!(
        r.reconnects("p"),
        1,
        "a connection after a full disconnect is a reconnect"
    );
}

#[test]
fn registry_tracks_each_pty_separately() {
    let r = BridgeRegistry::default();
    assert!(r.open("a"));
    assert!(r.open("b"));
    assert!(r.close("a"));
    assert_eq!(r.live("a"), 0);
    assert_eq!(r.live("b"), 1);
    assert_eq!(r.connected("b"), Some(true));
    assert_eq!(r.connected("c"), None);
}

#[test]
fn registry_ignores_the_empty_pty_id_and_never_underflows() {
    let r = BridgeRegistry::default();
    assert!(!r.open(""), "an unidentified caller is not tracked");
    assert_eq!(r.connected(""), None);
    assert_eq!(r.live(""), 0);
    assert!(!r.close(""));

    assert!(
        !r.close("never-opened"),
        "closing an unknown pty is a no-op"
    );
    assert_eq!(r.live("never-opened"), 0);
    assert!(r.open("never-opened"), "and does not corrupt later counts");
    assert_eq!(r.live("never-opened"), 1);
}

#[tokio::test]
async fn get_self_reports_a_single_live_bridge_connection() {
    let h = start().await;
    let mut a = Client::connect_as(&h.path, PTY).await;

    let info = a.get_self(1).await;
    assert_eq!(info["pty_id"], json!(PTY));
    assert_eq!(info["mcp_bridge_connected"], json!(true), "{info}");
    assert_eq!(info["mcp_bridge_connections"], json!(1), "{info}");
    assert_eq!(info["mcp_bridge_reconnects"], json!(0), "{info}");
}

#[tokio::test]
async fn a_second_connection_with_the_same_pty_id_raises_the_count_and_closing_one_lowers_it() {
    let h = start().await;
    let mut a = Client::connect_as(&h.path, PTY).await;
    assert_eq!(a.get_self(1).await["mcp_bridge_connections"], json!(1));

    let mut b = Client::connect_as(&h.path, PTY).await;
    let info = b.get_self(1).await;
    assert_eq!(info["mcp_bridge_connections"], json!(2), "{info}");
    assert_eq!(info["mcp_bridge_connected"], json!(true));

    drop(a); // closes both halves
    let registry = h.state.bridges.clone();
    eventually("the server to notice the first connection closing", || {
        registry.live(PTY) == 1
    })
    .await;

    let info = b.get_self(2).await;
    assert_eq!(info["mcp_bridge_connections"], json!(1), "{info}");
    assert_eq!(info["mcp_bridge_connected"], json!(true));
}

#[tokio::test]
async fn closing_every_connection_marks_the_pty_disconnected_and_a_new_one_counts_as_a_reconnect() {
    let h = start().await;
    let registry = h.state.bridges.clone();

    let mut a = Client::connect_as(&h.path, PTY).await;
    a.get_self(1).await;
    drop(a);

    eventually("the server to notice the connection closing", || {
        registry.live(PTY) == 0
    })
    .await;
    assert_eq!(registry.connected(PTY), Some(false));

    let mut b = Client::connect_as(&h.path, PTY).await;
    let info = b.get_self(1).await;
    assert_eq!(info["mcp_bridge_connected"], json!(true), "{info}");
    assert_eq!(info["mcp_bridge_connections"], json!(1), "{info}");
    assert_eq!(info["mcp_bridge_reconnects"], json!(1), "{info}");
}

#[tokio::test]
async fn bad_frames_do_not_make_the_server_count_the_connection_as_closed() {
    let h = start().await;
    let mut a = Client::connect_as(&h.path, PTY).await;
    a.send(b"\xff\xfe\n").await;
    assert_error(&a.recv().await, -32700);

    let info = a.get_self(1).await;
    assert_eq!(info["mcp_bridge_connections"], json!(1), "{info}");
    assert_eq!(info["mcp_bridge_connected"], json!(true));
}

// ── logging ───────────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_peer_disconnect_is_logged_with_the_pty_id_and_reason_and_no_frame_content() {
    let logs = captured_logs();
    let h = start().await;
    const LOG_PTY: &str = "log-pty-9c2e";
    const CANARY: &str = "CANARY-7f3a";

    let mut c = Client::connect_as(&h.path, LOG_PTY).await;
    // Canary in a well-formed request, a tool call, a malformed frame and a
    // non-UTF-8 frame: none of it may ever reach the log.
    c.send_json(&json!({"jsonrpc":"2.0","id":1,"method":"ping","params":{"q":CANARY}}))
        .await;
    c.recv().await;
    c.send_json(&json!({
        "jsonrpc":"2.0","id":2,"method":"tools/call",
        "params":{"name":"nostromo.get_self","arguments":{"q":CANARY}}
    }))
    .await;
    c.recv().await;
    c.send(format!("{{\"q\":\"{CANARY}\" oops\n").as_bytes())
        .await;
    c.recv().await;
    let mut bad = vec![0xffu8, 0xfe];
    bad.extend_from_slice(CANARY.as_bytes());
    bad.push(b'\n');
    c.send(&bad).await;
    c.recv().await;

    drop(c); // peer disconnects

    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    loop {
        let text = logs.text();
        if text
            .lines()
            .any(|l| l.contains(LOG_PTY) && l.contains("peer_eof"))
        {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "expected an INFO line with the pty id and reason peer_eof; captured:\n{text}"
        );
        sleep(Duration::from_millis(10)).await;
    }

    let text = logs.text();
    assert!(
        !text.contains(CANARY),
        "frame content leaked into the log:\n{text}"
    );
}
