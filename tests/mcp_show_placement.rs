//! Socket-level integration tests for `nostromo.show` (W5 —
//! curated-agent-views): the curated view surface and the scoped tool
//! withdrawal, both driven end to end over a real Unix socket against a
//! real daemon-hosted `McpSharedState`.
//!
//! This file deliberately does **not** re-derive anything `src/mcp/views/*`'s
//! 92 in-file tests or `src/mcp/tool_policy.rs`'s own tests already cover —
//! R1/R3/R6/R7 and the config/loading mechanics are exercised there against
//! `place()` and `ToolPolicy` directly, which is the right altitude for them.
//! What can only be shown by going through a real socket is: the closed
//! vocabulary actually reaching `tools/list`, a real `nostromo.show` call
//! landing content via real broadcasts with no raw pane tool ever touched,
//! and the withdrawal actually gating `tools/list` and `tools/call` for one
//! caller while leaving every other caller's surface alone.
//!
//! Mirrors `tests/mcp_daemon_panes.rs` and `tests/mcp_perri_mutators_daemon.rs`'s
//! harness shape.

use std::ffi::OsString;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{FocusMeta, ServerMsg};
use nostromo::ipc::SessionManager;
use nostromo::mcp::server::TOOL_FORBIDDEN_CODE;
use nostromo::mcp::tool_policy::INTENDED_PERRI_POLICY;
use nostromo::mcp::tools::tool_descriptors;
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState, PerriDaemonState, TicketRegistryState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::broadcast;

// ── `$HOME` isolation ────────────────────────────────────────────────────────
//
// `nostromo.show`'s handler (`views::config::load()`) and the withdrawal
// mechanism (`tool_policy::load()`) both resolve `~/.nostromo` via
// `dirs_next::home_dir()` — which reads `$HOME` on Unix — fresh on every
// call, by design (no caching, so an operator's edit takes effect with no
// restart). That is also the *only* place either of them can be pointed
// somewhere else: there is no `src`-level injection point, and this
// developer machine has a real `nostromd` writing into the real
// `~/.nostromo` right now (a live `mcp-daemon.sock`, `daemon-panes.json`,
// etc.) — tests must not read *or* write that directory. Overriding `$HOME`
// for the duration of a guard is therefore the correct injection point, not
// an invented one: it is exactly how the production binary itself resolves
// "the operator's `~/.nostromo`," just pointed at a private tempdir instead.
//
// `$HOME` is process-global, so every test in this file takes the same lock
// for its entire body — including the tests that never touch a policy file,
// since `tool_policy::load()` runs on *every* `tools/list` and `tools/call`
// regardless of relevance, and would otherwise race a sibling test's
// temporary `$HOME`.
static HOME_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

struct HomeOverride {
    _lock: MutexGuard<'static, ()>,
    dir: TempDir,
    previous: Option<OsString>,
}

impl HomeOverride {
    fn new() -> Self {
        let lock = HOME_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = TempDir::new().expect("tempdir for $HOME override");
        std::fs::create_dir_all(dir.path().join(".nostromo")).unwrap();
        let previous = std::env::var_os("HOME");
        std::env::set_var("HOME", dir.path());
        Self {
            _lock: lock,
            dir,
            previous,
        }
    }

    fn write_tool_policy(&self, yaml: &str) {
        std::fs::write(self.dir.path().join(".nostromo").join("tool-policy.yaml"), yaml)
            .expect("write tool-policy.yaml");
    }
}

impl Drop for HomeOverride {
    fn drop(&mut self) {
        match self.previous.take() {
            Some(v) => std::env::set_var("HOME", v),
            None => std::env::remove_var("HOME"),
        }
    }
}

// ── daemon harness ────────────────────────────────────────────────────────────

struct Harness {
    state: McpSharedState,
    broadcast_tx: broadcast::Sender<ServerMsg>,
    session_mgr: Arc<std::sync::Mutex<SessionManager>>,
    dir: TempDir,
}

fn make_daemon_state() -> Harness {
    let dir = TempDir::new().unwrap();
    let pane_registry = Arc::new(std::sync::Mutex::new(PaneRegistry::with_store_path(
        dir.path().join("panes.json"),
    )));
    let session_mgr = Arc::new(std::sync::Mutex::new(SessionManager::with_store_path(
        dir.path().join("sessions.json"),
    )));
    let (broadcast_tx, _rx) = broadcast::channel::<ServerMsg>(64);

    let backend = DaemonMcpBackend {
        pane_registry,
        session_mgr: session_mgr.clone(),
        broadcast_tx: broadcast_tx.clone(),
        perri: PerriDaemonState::default(),
        decisions: Arc::new(std::sync::Mutex::new(
            nostromo::ipc::decisions::DecisionRegistry::default(),
        )),
        tickets: TicketRegistryState::default(),
    };
    Harness {
        state: McpSharedState::for_daemon(backend),
        broadcast_tx,
        session_mgr,
        dir,
    }
}

/// Register `tags` in the focus registry, each its own agent name — what
/// makes `tool_policy::resolve_agent_name` resolve a Hello `pty_id` of e.g.
/// `"perri"` to the agent name `"perri"`, exactly as it does for a built-in
/// focus in production.
fn register_focuses(harness: &Harness, tags: &[&str]) {
    let metas = tags
        .iter()
        .map(|t| FocusMeta {
            tag: t.to_string(),
            display_name: t.to_string(),
            agent_name: t.to_string(),
            project_name: None,
            org: None,
            is_built_in: true,
            session_summary: None,
        })
        .collect();
    harness.session_mgr.lock().unwrap().set_focus_registry(metas);
}

// ── wire helpers ──────────────────────────────────────────────────────────────

async fn write_frame<W: AsyncWriteExt + Unpin>(w: &mut W, v: &Value) {
    let mut bytes = serde_json::to_vec(v).unwrap();
    bytes.push(b'\n');
    w.write_all(&bytes).await.unwrap();
}

async fn read_frame<R: tokio::io::AsyncRead + Unpin>(r: &mut BufReader<R>) -> Value {
    let mut line = String::new();
    r.read_line(&mut line).await.unwrap();
    serde_json::from_str(line.trim()).expect("response should be valid JSON")
}

/// Connect, send Hello with `tag` as `pty_id`, and complete `initialize`.
async fn connect(
    socket_path: &std::path::Path,
    tag: &str,
) -> (
    BufReader<tokio::net::unix::OwnedReadHalf>,
    tokio::net::unix::OwnedWriteHalf,
) {
    let stream = UnixStream::connect(socket_path).await.unwrap();
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    write_frame(&mut write_half, &json!({"type":"hello","pty_id": tag})).await;
    write_frame(
        &mut write_half,
        &json!({
            "jsonrpc":"2.0","id":1,"method":"initialize",
            "params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}
        }),
    )
    .await;
    let _ = read_frame(&mut reader).await; // consume initialize response
    (reader, write_half)
}

/// `tools/list`, parsed to the plain `result.tools` array.
async fn list_tools(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    id: i64,
) -> Value {
    write_frame(
        writer,
        &json!({ "jsonrpc": "2.0", "id": id, "method": "tools/list" }),
    )
    .await;
    let resp = read_frame(reader).await;
    resp["result"]["tools"].clone()
}

/// Issue a `tools/call` expected to succeed; asserts there is no top-level
/// JSON-RPC `error` and returns the parsed tool-content object.
async fn call_tool(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    id: i64,
    name: &str,
    args: Value,
) -> Value {
    let resp = call_tool_raw(reader, writer, id, name, args).await;
    assert!(
        resp.get("error").is_none(),
        "tool {name} returned a JSON-RPC error: {resp}"
    );
    let text = resp["result"]["content"][0]["text"].as_str().unwrap();
    serde_json::from_str(text).expect("tool content should be JSON")
}

/// Issue a `tools/call` and return the raw JSON-RPC response untouched — for
/// tests that need to inspect a JSON-RPC-level `error` object (a forbidden or
/// unknown tool) rather than assert one is absent.
async fn call_tool_raw(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    id: i64,
    name: &str,
    args: Value,
) -> Value {
    write_frame(
        writer,
        &json!({
            "jsonrpc":"2.0","id": id,"method":"tools/call",
            "params":{"name": name, "arguments": args}
        }),
    )
    .await;
    read_frame(reader).await
}

fn pane_ids(self_info: &Value) -> Vec<String> {
    self_info["pane_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect()
}

async fn get_self(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    id: i64,
) -> Value {
    call_tool(reader, writer, id, "nostromo.get_self", json!({})).await
}

// ── real files for the `file` view ───────────────────────────────────────────

/// A tempdir rooted directly under the process's own working directory.
///
/// `nostromo.show`'s `file` fetch resolves a path against the calling focus's
/// *session* cwd, falling back to `std::env::current_dir()` when the focus
/// has none (`file_root` in `src/mcp/tools/apply_layout.rs`). Giving a bare
/// test focus a real session cwd means spawning a real child process through
/// `SessionManager::spawn_session` — there is no lighter injection point, and
/// inventing one in `src/` is out of bounds for this task — so the *process*
/// cwd fallback is this harness's real "session cwd" for every tag in this
/// file, exactly as it already is for `apply_layout.rs`'s own in-file tests
/// (which read `src/main.rs` the same way). This still reads a real file
/// through the real `SOURCE_FILE` fetch path; nothing about the daemon is
/// stubbed.
fn temp_file_root() -> TempDir {
    let cwd = std::env::current_dir().expect("process cwd");
    tempfile::Builder::new()
        .prefix("mcp-show-placement-")
        .tempdir_in(&cwd)
        .expect("tempdir under the process cwd")
}

/// Write `name` under `root` and return its path relative to the process
/// cwd — what a `file` target's `path` must be.
fn write_rel_file(root: &std::path::Path, name: &str, contents: &str) -> String {
    let full = root.join(name);
    std::fs::write(&full, contents).unwrap();
    let cwd = std::env::current_dir().expect("process cwd");
    full.strip_prefix(&cwd)
        .expect("tempdir is under the process cwd")
        .to_string_lossy()
        .replace('\\', "/")
}

// ── 1. the closed vocabulary reaches `tools/list` ─────────────────────────────

#[tokio::test]
async fn nostromo_show_is_listed_with_exactly_the_five_v1_types_and_no_activity() {
    let _home = HomeOverride::new();
    let harness = make_daemon_state();
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let tools = list_tools(&mut reader, &mut writer, 2).await;
    let show = tools
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "nostromo.show")
        .expect("nostromo.show must be listed");

    let types: Vec<&str> = show["inputSchema"]["properties"]["type"]["enum"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(
        types,
        vec!["review_queue", "pr_conversation", "pr_diff", "file", "ticket"]
    );
    assert!(!types.contains(&"activity"), "activity is not showable");
}

// ── 2. a successful review_queue show ─────────────────────────────────────────

#[tokio::test]
async fn a_bare_focus_can_show_the_review_queue_through_show_alone_and_the_result_names_where_it_landed(
) {
    let _home = HomeOverride::new();
    let harness = make_daemon_state();
    let mut bcast = harness.broadcast_tx.subscribe();
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    // No raw pane tool is called anywhere in this test — the queue region
    // does not exist yet, and `show` must create it itself (D5).
    let res = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.show",
        json!({ "type": "review_queue" }),
    )
    .await;

    assert_eq!(res["ok"], true);
    assert_eq!(res["region"], "queue");
    assert_eq!(res["pane_id"], "queue");
    assert_eq!(res["label"], "Queue");
    assert_eq!(res["tab_index"], 0);
    assert_eq!(res["reused"], false, "the queue region did not exist yet");
    assert_eq!(res["frontmost"], true);
    assert_eq!(res["evicted"], Value::Null);

    // The exact broadcast sequence: FocusLayout (focus taken, R5) then
    // PaneContent — nothing else.
    let first = bcast.recv().await.unwrap();
    let ServerMsg::FocusLayout {
        tag, focused_pane, ..
    } = &first
    else {
        panic!("expected FocusLayout, got {first:?}")
    };
    assert_eq!(tag, "perri");
    assert_eq!(focused_pane.as_deref(), Some("queue"));

    let second = bcast.recv().await.unwrap();
    let ServerMsg::PaneContent { pane_id, .. } = &second else {
        panic!("expected PaneContent, got {second:?}")
    };
    assert_eq!(pane_id, "queue");
    assert!(
        tokio::time::timeout(Duration::from_millis(50), bcast.recv())
            .await
            .is_err(),
        "and nothing else"
    );

    // The queue region is real: `get_self` sees it alongside `repl`.
    let info = get_self(&mut reader, &mut writer, 3).await;
    let mut ids = pane_ids(&info);
    ids.sort();
    assert_eq!(ids, vec!["queue".to_string(), "repl".to_string()]);
}

// ── 3. identity reuse ──────────────────────────────────────────────────────────

#[tokio::test]
async fn showing_the_same_file_at_a_different_line_reuses_one_tab_and_re_anchors_it() {
    let _home = HomeOverride::new();
    let harness = make_daemon_state();
    let mut bcast = harness.broadcast_tx.subscribe();
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let root = temp_file_root();
    let path = write_rel_file(root.path(), "a.rs", "one\ntwo\nthree\nfour\nfive\n");

    let first = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.show",
        json!({ "type": "file", "target": { "path": path }, "anchor": { "kind": "line", "line": 1 } }),
    )
    .await;
    assert_eq!(first["ok"], true);
    assert_eq!(first["reused"], false);
    let pane_id = first["pane_id"].as_str().unwrap().to_string();
    let _ = bcast.recv().await.unwrap(); // FocusLayout
    let _ = bcast.recv().await.unwrap(); // PaneContent

    let second = call_tool(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "file", "target": { "path": path }, "anchor": { "kind": "line", "line": 3 } }),
    )
    .await;
    assert_eq!(second["ok"], true);
    assert_eq!(second["reused"], true, "the same file is the same view (R2)");
    assert_eq!(second["pane_id"], pane_id, "reused onto the same pane");

    // Still one tab, not two.
    let info = get_self(&mut reader, &mut writer, 4).await;
    let count = pane_ids(&info).iter().filter(|p| p.starts_with("detail.")).count();
    assert_eq!(count, 1, "one tab, not two: {info}");

    // The re-anchor reached the wire.
    let _ = bcast.recv().await.unwrap(); // FocusLayout for the second show
    let ServerMsg::PaneContent { address, .. } = bcast.recv().await.unwrap() else {
        panic!("expected PaneContent")
    };
    let anchor = address.expect("a re-anchored show still addresses the pane").anchor;
    assert_eq!(
        anchor,
        Some(nostromo::ipc::protocol::Anchor::Line { path: None, line: 3 })
    );
}

// ── 4. refusals leave the tree untouched ──────────────────────────────────────

#[tokio::test]
async fn a_type_outside_the_vocabulary_is_refused_and_leaves_the_tree_untouched() {
    let _home = HomeOverride::new();
    let harness = make_daemon_state();
    let mut bcast = harness.broadcast_tx.subscribe();
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let before = pane_ids(&get_self(&mut reader, &mut writer, 2).await);

    let res = call_tool(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "terminal" }),
    )
    .await;
    assert_eq!(res["error"], "unknown_view_type");
    for t in ["review_queue", "pr_conversation", "pr_diff", "file", "ticket"] {
        assert!(res["detail"].as_str().unwrap().contains(t));
    }

    let after = pane_ids(&get_self(&mut reader, &mut writer, 4).await);
    assert_eq!(before, after, "the tree is untouched");
    assert!(
        tokio::time::timeout(Duration::from_millis(50), bcast.recv())
            .await
            .is_err(),
        "a refusal broadcasts nothing"
    );
}

#[tokio::test]
async fn an_activity_show_is_refused_with_its_own_error_and_leaves_the_tree_untouched() {
    let _home = HomeOverride::new();
    let harness = make_daemon_state();
    let mut bcast = harness.broadcast_tx.subscribe();
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let before = pane_ids(&get_self(&mut reader, &mut writer, 2).await);

    let res = call_tool(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "activity" }),
    )
    .await;
    assert_eq!(res["error"], "activity_not_pushable");
    assert_ne!(res["error"], "unknown_view_type");

    let after = pane_ids(&get_self(&mut reader, &mut writer, 4).await);
    assert_eq!(before, after, "the tree is untouched");
    assert!(
        tokio::time::timeout(Duration::from_millis(50), bcast.recv())
            .await
            .is_err()
    );
}

// ── 5. every view type opens through `show` alone ─────────────────────────────

#[tokio::test]
async fn review_queue_pr_conversation_pr_diff_and_file_all_open_through_show_alone() {
    let _home = HomeOverride::new();
    let harness = make_daemon_state();
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    // review_queue.
    let res = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.show",
        json!({ "type": "review_queue" }),
    )
    .await;
    assert_eq!(res["ok"], true, "review_queue: {res}");

    // pr_conversation and pr_diff: no PR is under review in this harness
    // (`perri_pr_rx` defaults to `None`), and both sources render "no PR
    // loaded" placeholder text rather than failing when that's the case —
    // so both open with no network call at all.
    let res = call_tool(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "pr_conversation", "target": { "repo": "acme/widgets", "number": 1 } }),
    )
    .await;
    assert_eq!(res["ok"], true, "pr_conversation: {res}");

    let res = call_tool(
        &mut reader,
        &mut writer,
        4,
        "nostromo.show",
        json!({ "type": "pr_diff", "target": { "repo": "acme/widgets", "number": 1 } }),
    )
    .await;
    assert_eq!(res["ok"], true, "pr_diff: {res}");

    // file: a real file, read through the real `SOURCE_FILE` fetch path.
    let root = temp_file_root();
    let path = write_rel_file(root.path(), "shown.rs", "fn main() {}\n");
    let res = call_tool(
        &mut reader,
        &mut writer,
        5,
        "nostromo.show",
        json!({ "type": "file", "target": { "path": path } }),
    )
    .await;
    assert_eq!(res["ok"], true, "file: {res}");
}

#[tokio::test]
async fn a_ticket_show_refuses_with_a_fetch_level_error_not_a_placement_or_vocabulary_one() {
    let _home = HomeOverride::new();
    let harness = make_daemon_state();
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let before = pane_ids(&get_self(&mut reader, &mut writer, 2).await);

    // This harness registers no ticket provider (`TicketRegistryState::default()`
    // — the same "empty registry" every test that doesn't itself exercise a
    // ticket source uses, per `src/mcp/state.rs`'s doc comment on
    // `TicketRegistryState`), so `ticket` cannot complete here: there is no
    // credentialed Jira to reach, in test or in CI. That is a *fetch-level*
    // refusal — `unsupported_provider`, from `TicketRegistry::get` — and it
    // is important that it is that and not `unknown_view_type` /
    // `invalid_target` / `unknown_region`: those would mean the vocabulary or
    // the placement engine rejected the show, when actually both accepted it
    // and only the network-shaped last step failed. This is the daemon's
    // real ticket-provider code path; nothing here is stubbed.
    let res = call_tool(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "ticket", "target": { "provider": "jira", "key": "CORE-1" } }),
    )
    .await;
    assert_eq!(res["error"], "unsupported_provider", "{res}");
    for placement_or_vocab_code in [
        "unknown_view_type",
        "activity_not_pushable",
        "invalid_target",
        "invalid_anchor",
        "invalid_emphasis",
        "unknown_region",
        "region_not_tabbed",
        "region_not_creatable",
        "pane_id_taken",
        "invalid_views_config",
    ] {
        assert_ne!(res["error"], placement_or_vocab_code);
    }

    // And, like every other refusal, it leaves the tree untouched — the
    // fetch runs before any mutation.
    let after = pane_ids(&get_self(&mut reader, &mut writer, 4).await);
    assert_eq!(before, after);
}

// ── 6. R4 — cap and eviction ───────────────────────────────────────────────────

#[tokio::test]
async fn the_seventh_tab_in_the_detail_region_evicts_the_least_recently_focused_non_frontmost_tab()
{
    let _home = HomeOverride::new();
    let harness = make_daemon_state();
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let root = temp_file_root();
    let mut pane_id_of = Vec::new();
    // Fill the compiled-in `tab_cap: 6` exactly, in order — each show also
    // takes focus (R5), so this is also the LRU order: f0 least recently
    // focused, f5 most recent (frontmost) going into the seventh show.
    for n in 0..6 {
        let path = write_rel_file(root.path(), &format!("f{n}.txt"), "one\ntwo\n");
        let res = call_tool(
            &mut reader,
            &mut writer,
            10 + n,
            "nostromo.show",
            json!({ "type": "file", "target": { "path": path } }),
        )
        .await;
        assert_eq!(res["ok"], true, "f{n}: {res}");
        assert_eq!(res["evicted"], Value::Null, "no eviction until the cap is hit");
        pane_id_of.push(res["pane_id"].as_str().unwrap().to_string());
    }

    let info = get_self(&mut reader, &mut writer, 20).await;
    assert_eq!(
        pane_ids(&info).iter().filter(|p| p.starts_with("detail.")).count(),
        6
    );

    // The seventh show evicts exactly one tab: the least-recently-focused,
    // non-pinned, non-frontmost one — f0, since nothing here is pinned (no PR
    // is under review) and f5 is frontmost.
    let path6 = write_rel_file(root.path(), "f6.txt", "one\ntwo\n");
    let res = call_tool(
        &mut reader,
        &mut writer,
        21,
        "nostromo.show",
        json!({ "type": "file", "target": { "path": path6 } }),
    )
    .await;
    assert_eq!(res["ok"], true);
    assert_eq!(
        res["evicted"],
        Value::String(pane_id_of[0].clone()),
        "f0 — least recently focused, non-frontmost — must be the one evicted"
    );

    let info = get_self(&mut reader, &mut writer, 22).await;
    let ids = pane_ids(&info);
    assert_eq!(
        ids.iter().filter(|p| p.starts_with("detail.")).count(),
        6,
        "the cap holds: still six tabs, not seven"
    );
    assert!(
        !ids.contains(&pane_id_of[0]),
        "the evicted pane is actually gone from the tree"
    );
    for surviving in &pane_id_of[1..] {
        assert!(ids.contains(surviving), "f1..f5 survive: {ids:?}");
    }
}

// ── 7. R8 — a PR change resets the review context ─────────────────────────────

#[tokio::test]
async fn showing_a_pr_conversation_for_a_different_pr_closes_the_previous_reviews_conversation_diff_and_file_tabs(
) {
    let _home = HomeOverride::new();
    let harness = make_daemon_state();
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let old_conversation = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.show",
        json!({ "type": "pr_conversation", "target": { "repo": "acme/widgets", "number": 1 } }),
    )
    .await["pane_id"]
        .as_str()
        .unwrap()
        .to_string();

    let root = temp_file_root();
    let path = write_rel_file(root.path(), "reviewed.rs", "fn a() {}\n");
    let old_file = call_tool(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "file", "target": { "path": path } }),
    )
    .await["pane_id"]
        .as_str()
        .unwrap()
        .to_string();

    let old_diff = call_tool(
        &mut reader,
        &mut writer,
        4,
        "nostromo.show",
        json!({ "type": "pr_diff", "target": { "repo": "acme/widgets", "number": 1 } }),
    )
    .await["pane_id"]
        .as_str()
        .unwrap()
        .to_string();

    // A show naming a *different* PR: R8 fires as part of this very show
    // (`place()`'s own displacement check — not `perri.load_pr`, which is
    // R8's *other* trigger and is exercised by `src/mcp/tools/show.rs`'s own
    // `reset_for_pr_change` and by `perri_mutators.rs`). Everything that
    // belonged to the old review — the old conversation, the old diff, and
    // the file tab, which names no PR at all and so can never "belong" to
    // the new one — closes; only the new PR's own conversation tab survives.
    let res = call_tool(
        &mut reader,
        &mut writer,
        5,
        "nostromo.show",
        json!({ "type": "pr_conversation", "target": { "repo": "startronics/gadgets", "number": 2 } }),
    )
    .await;
    assert_eq!(res["ok"], true);
    assert_eq!(res["reused"], false, "a genuinely new PR is a new tab");
    let mut closed: Vec<String> = res["closed"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    closed.sort();
    let mut expected = vec![old_conversation.clone(), old_file.clone(), old_diff.clone()];
    expected.sort();
    assert_eq!(closed, expected, "the whole previous review closes");

    let ids = pane_ids(&get_self(&mut reader, &mut writer, 6).await);
    for gone in [&old_conversation, &old_file, &old_diff] {
        assert!(!ids.contains(gone), "{gone} must actually be gone: {ids:?}");
    }

    // Ticket tabs belong to no review any more concretely than `file` does
    // (`ViewIdentity::Ticket::pr()` is also `None`), so the engine-level
    // rule (`reset_for_pr_change_closes_file_and_ticket_tabs_and_leaves_the_new_prs_views`
    // in `src/mcp/views/placement.rs`) already covers a ticket tab closing
    // the same way `file` does here; a ticket tab cannot be landed through
    // this socket at all without a configured provider (see the
    // `a_ticket_show_refuses...` test above), so it is not repeated here.
}

#[tokio::test]
async fn a_show_for_the_pr_already_under_review_does_not_reset_anything() {
    let _home = HomeOverride::new();
    let harness = make_daemon_state();
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let conversation = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.show",
        json!({ "type": "pr_conversation", "target": { "repo": "acme/widgets", "number": 1 } }),
    )
    .await["pane_id"]
        .as_str()
        .unwrap()
        .to_string();

    // A `pr_diff` show for the *same* PR must not trigger the displacement
    // reset: nothing to close, and the surviving conversation tab is left
    // exactly where it was.
    let res = call_tool(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "pr_diff", "target": { "repo": "acme/widgets", "number": 1 } }),
    )
    .await;
    assert_eq!(res["ok"], true);
    assert_eq!(res["closed"], json!([]), "nothing closes for a matching PR");

    let ids = pane_ids(&get_self(&mut reader, &mut writer, 4).await);
    assert!(ids.contains(&conversation), "the conversation tab survives");
}

// ── 8. scoped withdrawal — perri loses the seven raw tools ────────────────────

const RAW_PANE_TOOLS: [&str; 7] = [
    "nostromo.set_pane_content",
    "nostromo.set_pane_layout",
    "nostromo.set_pane_focus",
    "nostromo.create_pane",
    "nostromo.reset_panes",
    "nostromo.apply_layout",
    "nostromo.refresh_pane_content",
];

#[tokio::test]
async fn a_policy_denying_perri_removes_the_seven_raw_tools_from_her_list_and_refuses_her_calls_distinctly_from_unknown_tool(
) {
    let home = HomeOverride::new();
    home.write_tool_policy(INTENDED_PERRI_POLICY);

    let harness = make_daemon_state();
    register_focuses(&harness, &["perri", "mother", "fred", "teri"]);
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let tools = list_tools(&mut reader, &mut writer, 2).await;
    let names: Vec<&str> = tools
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    for denied in RAW_PANE_TOOLS {
        assert!(!names.contains(&denied), "{denied} must not be listed for perri");
    }
    assert!(
        names.contains(&"nostromo.show"),
        "the curated surface itself must stay"
    );
    assert!(
        names.contains(&"nostromo.get_self"),
        "an undenied tool must stay listed"
    );

    // The list is advisory; the call gate is the half that actually holds.
    for (i, denied) in RAW_PANE_TOOLS.iter().enumerate() {
        let resp = call_tool_raw(&mut reader, &mut writer, 10 + i as i64, denied, json!({})).await;
        let code = resp["error"]["code"].as_i64().expect("a JSON-RPC error");
        assert_eq!(code, TOOL_FORBIDDEN_CODE, "{denied}: {resp}");
        assert_ne!(code, -32601, "{denied}: must not look like Method not found");
        let message = resp["error"]["message"].as_str().unwrap_or("");
        assert!(
            !message.to_lowercase().contains("method not found"),
            "{denied}: message must read as a withdrawal, not a typo: {message}"
        );
    }

    // An unknown tool name still gets the ordinary -32601, so the two really
    // are distinguishable at the wire.
    let resp = call_tool_raw(&mut reader, &mut writer, 99, "nostromo.not_a_real_tool", json!({})).await;
    assert_eq!(resp["error"]["code"], -32601);
    assert_ne!(resp["error"]["code"], TOOL_FORBIDDEN_CODE);
}

// ── 9. scoped withdrawal — everyone else is untouched ─────────────────────────

#[tokio::test]
async fn the_same_policy_that_denies_perri_leaves_mother_fred_and_teris_tool_lists_unchanged_and_their_calls_working(
) {
    let home = HomeOverride::new();
    home.write_tool_policy(INTENDED_PERRI_POLICY);

    let harness = make_daemon_state();
    register_focuses(&harness, &["perri", "mother", "fred", "teri"]);
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();

    let unfiltered = Value::Array(tool_descriptors());

    for agent in ["mother", "fred", "teri"] {
        let (mut reader, mut writer) = connect(&socket_path, agent).await;
        let tools = list_tools(&mut reader, &mut writer, 2).await;
        assert_eq!(tools, unfiltered, "{agent}'s list must be byte-for-byte unchanged");

        // And the raw tools they were never denied still work.
        let res = call_tool(
            &mut reader,
            &mut writer,
            3,
            "nostromo.apply_layout",
            json!({ "name": "perri-standard" }),
        )
        .await;
        assert_eq!(res["ok"], true, "{agent} must still be able to call it: {res}");
    }
}

// ── 10. scoped withdrawal — an unresolved caller is never filtered ────────────

#[tokio::test]
async fn a_caller_whose_agent_name_cannot_be_resolved_is_never_filtered() {
    let home = HomeOverride::new();
    home.write_tool_policy(INTENDED_PERRI_POLICY);

    let harness = make_daemon_state();
    // Deliberately register nothing — every tag below fails to resolve.
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();

    let unfiltered = Value::Array(tool_descriptors());

    // An empty `pty_id` (no Hello identity at all).
    {
        let (mut reader, mut writer) = connect(&socket_path, "").await;
        let tools = list_tools(&mut reader, &mut writer, 2).await;
        assert_eq!(tools, unfiltered, "an empty pty_id must fail open");
        let res = call_tool(
            &mut reader,
            &mut writer,
            3,
            "nostromo.apply_layout",
            json!({ "name": "perri-standard" }),
        )
        .await;
        assert_eq!(res["ok"], true, "and must not be refused: {res}");
    }

    // A tag with no focus-registry entry at all.
    {
        let (mut reader, mut writer) = connect(&socket_path, "ghost-unregistered-tag").await;
        let tools = list_tools(&mut reader, &mut writer, 2).await;
        assert_eq!(tools, unfiltered, "an unknown tag must fail open");
        let res = call_tool(
            &mut reader,
            &mut writer,
            3,
            "nostromo.apply_layout",
            json!({ "name": "perri-standard" }),
        )
        .await;
        assert_eq!(res["ok"], true, "and must not be refused: {res}");
    }
}

// ── 11. scoped withdrawal — shipped inert by default ──────────────────────────

#[tokio::test]
async fn with_no_policy_file_present_every_caller_including_perri_sees_the_unfiltered_list() {
    let _home = HomeOverride::new(); // no `write_tool_policy` call — the shipped default.

    let harness = make_daemon_state();
    register_focuses(&harness, &["perri"]);
    let socket_path = harness.dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let tools = list_tools(&mut reader, &mut writer, 2).await;
    assert_eq!(tools, Value::Array(tool_descriptors()));

    for tool in RAW_PANE_TOOLS {
        let names: Vec<&str> = tools
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&tool), "{tool} must still be listed for perri");
    }
}
