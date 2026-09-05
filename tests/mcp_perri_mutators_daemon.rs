//! End-to-end integration test for Perri's mutating MCP tools under the
//! **daemon-hosted** MCP server.
//!
//! Before this fix, `perri.load_pr`, `perri.clear_current_pr`,
//! `perri.set_selected_index` unconditionally posted an `AppEvent::McpCommand`
//! and waited on a oneshot reply — a path that only the standalone TUI's own
//! event loop ever drained. Under `nostromd` nothing consumes that channel,
//! so every call burned the full 5s command timeout and returned
//! `{"error":"event_loop_timeout"}`. `perri.get_selected_index` wasn't even
//! registered as a tool. This test drives all four over a real Unix socket
//! against a daemon-hosted `McpSharedState` and asserts none of that happens
//! anymore.
//!
//! Mirrors `tests/mcp_daemon_panes.rs`'s harness.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::SessionManager;
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState, PerriDaemonState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::broadcast;

// ── helpers ───────────────────────────────────────────────────────────────────

struct Harness {
    state: McpSharedState,
    _dir: TempDir,
    perri_state_dir: std::path::PathBuf,
    /// The daemon's own broadcast sender, so a test can subscribe and read the
    /// wire messages a tool call produced — including, for the "no gate"
    /// criterion, the `DecisionRequest` that must never appear.
    broadcast_tx: broadcast::Sender<ServerMsg>,
    /// The decision registry the daemon submits modal requests into. A pickup
    /// must never put anything here.
    decisions: Arc<Mutex<nostromo::ipc::decisions::DecisionRegistry>>,
}

fn make_daemon_state() -> Harness {
    let dir = TempDir::new().unwrap();
    let perri_state_dir = dir.path().join("perri-state");
    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        dir.path().join("panes.json"),
    )));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        dir.path().join("sessions.json"),
    )));
    let (broadcast_tx, _rx) = broadcast::channel::<ServerMsg>(64);
    let decisions = Arc::new(Mutex::new(
        nostromo::ipc::decisions::DecisionRegistry::default(),
    ));

    let backend = DaemonMcpBackend {
        pane_registry,
        session_mgr,
        broadcast_tx: broadcast_tx.clone(),
        perri: PerriDaemonState {
            state_dir: Some(perri_state_dir.clone()),
            pr_refresh_tx: None,
            queue_refresh_tx: None,
            selected_index: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            // Short settle timeout so a load_pr call with no matching
            // snapshot (the common case in this test — no real GitHub
            // fetch happens) resolves quickly instead of waiting 12s.
            settle_timeout: Duration::from_millis(100),
        },
        decisions: decisions.clone(),
        tickets: Default::default(),
    };
    Harness {
        state: McpSharedState::for_daemon(backend),
        _dir: dir,
        perri_state_dir,
        broadcast_tx,
        decisions,
    }
}

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

/// Connect, send Hello with `tag` as pty_id, and complete `initialize`.
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

/// Issue a `tools/call`, assert it resolved within `within` (proving it did
/// not fall into the 5s `event_loop_timeout` trap), and return the parsed
/// tool result object.
async fn call_tool_bounded<W: AsyncWriteExt + Unpin, R: tokio::io::AsyncRead + Unpin>(
    reader: &mut BufReader<R>,
    writer: &mut W,
    id: i64,
    name: &str,
    args: Value,
    within: Duration,
) -> Value {
    write_frame(
        writer,
        &json!({
            "jsonrpc":"2.0","id": id,"method":"tools/call",
            "params":{"name": name, "arguments": args}
        }),
    )
    .await;
    let resp = tokio::time::timeout(within, read_frame(reader))
        .await
        .unwrap_or_else(|_| panic!("{name} did not respond within {within:?}"));
    assert!(
        resp.get("error").is_none(),
        "tool {name} returned a JSON-RPC error: {resp}"
    );
    let text = resp["result"]["content"][0]["text"].as_str().unwrap();
    let value: Value = serde_json::from_str(text).expect("tool content should be JSON");
    assert_ne!(
        value.get("error").and_then(|e| e.as_str()),
        Some("event_loop_timeout"),
        "{name} fell back to the TUI event-loop path and timed out: {value}"
    );
    assert_ne!(
        value.get("error").and_then(|e| e.as_str()),
        Some("event_loop_closed"),
        "{name} fell back to the TUI event-loop path and found it closed: {value}"
    );
    value
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn all_four_perri_mutators_never_hit_the_event_loop_timeout_path() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    // Seed the perri-standard layout so diff/queue panes exist for the
    // caller's own focus ("perri", from the Hello pty_id).
    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-standard" }),
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(res["ok"], true);

    // A generous bound well under the old 5s COMMAND_TIMEOUT_SECS trap —
    // if any of these regress to the TUI event-loop fallback, this fails
    // loudly instead of silently passing after a 5s stall.
    let bound = Duration::from_millis(1500);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        3,
        "perri.load_pr",
        json!({ "number": 42, "repo": "acme/web", "highlights": "check auth" }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    // W7: the pin is sharded per focus. This caller connected with pty_id
    // "perri", so its pin is that focus's — not a machine-wide file.
    let pointer_path =
        nostromo::data::perri_current_pr::pin_path(&harness.perri_state_dir, "perri").unwrap();
    assert!(
        pointer_path.exists(),
        "perri.load_pr must write the calling focus's pin into the daemon's Perri state dir"
    );
    let pointer: Value =
        serde_json::from_str(&std::fs::read_to_string(&pointer_path).unwrap()).unwrap();
    assert_eq!(pointer["number"], 42);
    assert_eq!(pointer["repo"], "acme/web");

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        4,
        "perri.set_selected_index",
        json!({ "index": 0 }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        5,
        "perri.get_selected_index",
        json!({}),
        bound,
    )
    .await;
    assert_eq!(res["index"], 0);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        6,
        "perri.clear_current_pr",
        json!({}),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);
    assert!(
        !pointer_path.exists(),
        "perri.clear_current_pr must remove current-pr.json"
    );
}

#[tokio::test]
async fn load_pr_without_highlights_settles_or_reports_pending_quickly() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon2.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let _ = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-standard" }),
        Duration::from_secs(1),
    )
    .await;

    // No highlights, and nothing will ever publish a matching snapshot in
    // this test (there's no real native source running) — the 100ms settle
    // timeout configured in make_daemon_state() must still make this call
    // return promptly with `pending: true`, not hang for 5s.
    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        3,
        "perri.load_pr",
        json!({ "number": 7, "repo": "acme/anvil" }),
        Duration::from_millis(1500),
    )
    .await;
    assert_eq!(res["ok"], true);
    assert_eq!(res["pending"], true);
}

/// End-to-end: `perri.clear_current_pr` on a **curated** focus (a layout
/// where the only fixed pane is `queue` — the review's detail panes are
/// created on demand by `nostromo.show`, named `detail.0`/`detail.1`/…, not
/// the legacy `diff`) must still find and close the review tab it opened.
/// Before this fix, `clear_current_pr`'s daemon branch only ever pushed to
/// panes literally named `"diff"`/`"queue"`, so on this layout it was a
/// silent no-op: `ok: true`, nothing closed, no content pushed, no visible
/// error — exactly the bug this fix targets.
#[tokio::test]
async fn clear_current_pr_over_the_real_socket_closes_a_curated_pr_diff_tab() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon3.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let bound = Duration::from_millis(1500);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-curated" }),
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "pr_diff", "target": { "repo": "acme/web", "number": 42 } }),
        bound,
    )
    .await;
    assert_eq!(
        res["ok"], true,
        "nostromo.show should open the pr_diff tab: {res}"
    );

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        4,
        "perri.clear_current_pr",
        json!({}),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);
    assert!(
        res.get("warnings").is_none(),
        "a healthy clear on a layout it actually applied must never warn: {res}"
    );
    let closed = res["closed"]
        .as_array()
        .expect("`closed` must be present and an array");
    assert!(
        !closed.is_empty(),
        "the pr_diff tab nostromo.show just opened must have been closed: {res}"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// W7 — the PR under review is a property of the focus
// ═════════════════════════════════════════════════════════════════════════════
//
// Everything below drives the same real Unix socket the tests above do, with
// **two connections whose Hello frames name two different focuses**. That is
// the whole point: before W7 the daemon had one "PR under review" for the
// machine and the second connection silently overwrote the first's, which is
// the 2026-09-04 incident recorded in
// `.claude/bugs/open/2026-09-04-current-pr-slot-is-a-single-global-pin-…md`.
//
// Two seams are deliberately *not* mocked: the pin store (real files under the
// daemon's Perri state dir) and the resolution path a file request runs
// (`nostromo.show` → `file_request_context` → `git show`). The one thing these
// tests stand in for is the native GitHub source, which no test may reach: a
// pin becomes a published `PrSnapshot` here through `set_pr_for`, exactly as
// the daemon's own source would publish it after a fetch.

// ── helpers ──────────────────────────────────────────────────────────────────

/// A published PR snapshot for `tag`, as the native source would publish it
/// once it had fetched that focus's pin.
fn publish_pr(state: &McpSharedState, tag: &str, repo: &str, number: u64, head_sha: &str) {
    let snap: nostromo::data::perri_pr::PrSnapshot = serde_json::from_value(json!({
        "pr_number": number,
        "repo": repo,
        "title": format!("{repo}#{number}"),
        "author": "alice",
        "url": format!("https://github.com/{repo}/pull/{number}"),
        "diff": "",
        "stale": false,
        "error": null,
        "additions": 1,
        "deletions": 1,
        "changed_files": 1,
        "head_sha": head_sha,
        "diff_too_large": false
    }))
    .unwrap();
    state.set_pr_for(tag, snap);
}

/// `tag`'s pin file, exactly as it sits on disk. `None` when that focus has no
/// PR under review.
fn pin_bytes(harness: &Harness, tag: &str) -> Option<Vec<u8>> {
    let path = nostromo::data::perri_current_pr::pin_path(&harness.perri_state_dir, tag).unwrap();
    std::fs::read(path).ok()
}

/// `(repo, number)` from `tag`'s pin file. Panics when there is no pin — a
/// pickup that wrote nothing is a failure, not an empty answer.
fn pinned(harness: &Harness, tag: &str) -> (String, u64) {
    let raw = pin_bytes(harness, tag)
        .unwrap_or_else(|| panic!("focus {tag:?} must have a pin file after a pickup"));
    let v: Value = serde_json::from_slice(&raw).unwrap();
    (
        v["repo"].as_str().unwrap().to_owned(),
        v["number"].as_u64().unwrap(),
    )
}

/// Bind an `McpServer` for `harness` on a socket named after the test.
async fn serve(harness: &Harness, name: &str) -> (McpServer, std::path::PathBuf) {
    let socket_path = harness._dir.path().join(format!("{name}.sock"));
    let server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");
    (server, socket_path)
}

/// A generous bound, well under the 5s `event_loop_timeout` trap.
const BOUND: Duration = Duration::from_millis(2000);

/// Every `PaneContent` push currently sitting in `bcast`.
fn drained_pane_content(
    bcast: &mut broadcast::Receiver<ServerMsg>,
) -> Vec<(String, String, nostromo::ipc::protocol::PaneContentWire)> {
    let mut out = Vec::new();
    while let Ok(msg) = bcast.try_recv() {
        if let ServerMsg::PaneContent {
            tag,
            pane_id,
            content,
            ..
        } = msg
        {
            out.push((tag, pane_id, content));
        }
    }
    out
}

// ── 1. two focuses, two PRs ──────────────────────────────────────────────────

#[tokio::test]
async fn two_focuses_each_report_their_own_pr_under_review_and_never_the_other_s() {
    let harness = make_daemon_state();
    let (_server, socket) = serve(&harness, "two-focuses").await;

    let (mut ra, mut wa) = connect(&socket, "focus-a").await;
    let (mut rb, mut wb) = connect(&socket, "focus-b").await;

    // Two pickups, in two focuses, through the tool an agent actually calls.
    let res = call_tool_bounded(
        &mut ra,
        &mut wa,
        2,
        "perri.load_pr",
        json!({ "number": 4526, "repo": "Carefeed/admin-portal", "highlights": "recipients" }),
        BOUND,
    )
    .await;
    assert_eq!(res["ok"], true, "focus A's pickup must succeed: {res}");

    let res = call_tool_bounded(
        &mut rb,
        &mut wb,
        2,
        "perri.load_pr",
        json!({ "number": 42, "repo": "Carefeed/operations", "highlights": "tailwind" }),
        BOUND,
    )
    .await;
    assert_eq!(
        res["ok"], true,
        "focus B's pickup must succeed while A holds one — there is no gate: {res}"
    );

    // Each pin landed in its own focus's file, and neither overwrote the other.
    assert_eq!(
        pinned(&harness, "focus-a"),
        ("Carefeed/admin-portal".into(), 4526)
    );
    assert_eq!(
        pinned(&harness, "focus-b"),
        ("Carefeed/operations".into(), 42)
    );

    publish_pr(
        &harness.state,
        "focus-a",
        "Carefeed/admin-portal",
        4526,
        "sha-a",
    );
    publish_pr(
        &harness.state,
        "focus-b",
        "Carefeed/operations",
        42,
        "sha-b",
    );

    let a = call_tool_bounded(
        &mut ra,
        &mut wa,
        3,
        "perri.get_current_pr",
        json!({}),
        BOUND,
    )
    .await;
    assert_eq!(a["repo"], "Carefeed/admin-portal");
    assert_eq!(a["pr_number"], 4526);

    let b = call_tool_bounded(
        &mut rb,
        &mut wb,
        3,
        "perri.get_current_pr",
        json!({}),
        BOUND,
    )
    .await;
    assert_eq!(
        b["repo"], "Carefeed/operations",
        "focus B must report its own PR, not whichever was picked up last: {b}"
    );
    assert_eq!(b["pr_number"], 42);
}

// ── 2. two focuses, two PRs in ONE repo ──────────────────────────────────────

/// The criterion that forecloses "just scope it by repo". Scoping by repo
/// resolves the recorded incident (two repos) while still failing this, which
/// is the ordinary case of one reviewer working a queue.
#[tokio::test]
async fn two_focuses_reviewing_two_prs_in_the_same_repo_do_not_affect_each_other() {
    let harness = make_daemon_state();
    let (_server, socket) = serve(&harness, "same-repo").await;

    let (mut ra, mut wa) = connect(&socket, "focus-a").await;
    let (mut rb, mut wb) = connect(&socket, "focus-b").await;

    let res = call_tool_bounded(
        &mut ra,
        &mut wa,
        2,
        "perri.load_pr",
        json!({ "number": 4526, "repo": "Carefeed/admin-portal", "highlights": "x" }),
        BOUND,
    )
    .await;
    assert_eq!(res["ok"], true, "{res}");
    let res = call_tool_bounded(
        &mut rb,
        &mut wb,
        2,
        "perri.load_pr",
        json!({ "number": 4530, "repo": "Carefeed/admin-portal", "highlights": "y" }),
        BOUND,
    )
    .await;
    assert_eq!(res["ok"], true, "{res}");

    assert_eq!(
        pinned(&harness, "focus-a"),
        ("Carefeed/admin-portal".into(), 4526)
    );
    assert_eq!(
        pinned(&harness, "focus-b"),
        ("Carefeed/admin-portal".into(), 4530),
        "a second PR in the same repo is a second review, not the same one"
    );

    publish_pr(
        &harness.state,
        "focus-a",
        "Carefeed/admin-portal",
        4526,
        "sha-4526",
    );
    publish_pr(
        &harness.state,
        "focus-b",
        "Carefeed/admin-portal",
        4530,
        "sha-4530",
    );

    let a = call_tool_bounded(
        &mut ra,
        &mut wa,
        3,
        "perri.get_current_pr",
        json!({}),
        BOUND,
    )
    .await;
    let b = call_tool_bounded(
        &mut rb,
        &mut wb,
        3,
        "perri.get_current_pr",
        json!({}),
        BOUND,
    )
    .await;
    assert_eq!(a["pr_number"], 4526);
    assert_eq!(a["head_sha"], "sha-4526");
    assert_eq!(
        b["pr_number"], 4530,
        "sharing a repo must not make two focuses share a review: {b}"
    );
    assert_eq!(b["head_sha"], "sha-4530");
}

// ── 3. THE RECORDED INCIDENT ─────────────────────────────────────────────────
//
// A file request resolves against *the asking focus's* PR — its repo and its
// revision — whatever any other focus is reviewing.
//
// ### Why this fixture, and what it does and does not stand in for
//
// `file_root` resolves a focus's root to its **session cwd**, and giving a
// test focus one means spawning a real `claude` child (see the same note in
// `tests/mcp_show_placement.rs`) — there is no lighter injection point. So
// both focuses here share the one root every integration test has: the process
// cwd. What differs between them is the *revision*, which is exactly the seam
// W7 changed: pre-W7 `head_sha` was daemon-global while the root was already
// per-focus, and the mismatch between those two is the incident.
//
// The revisions are real git commits in a throwaway repo, reachable from the
// ambient repo through `GIT_ALTERNATE_OBJECT_DIRECTORIES` — so `git show` in
// the daemon does real work against real objects, nothing is stubbed, and no
// commit, ref or file is ever written into the operator's own repository. The
// two commits are parent and child on purpose: both SHAs then resolve, so a
// request that resolved against the *wrong* one fails with the incident's own
// `unknown_path` rather than the different, weaker `unresolvable_revision`
// (which would also reach for the network).

use std::sync::OnceLock;

/// The path the incident's `nostromo.show` asked for and got `unknown_path`.
const INCIDENT_PATH: &str = "app/Services/ContactRecipientService.php";
const INCIDENT_FILE_BODY: &str = "<?php\nclass ContactRecipientService {}\n";
/// Content for a path that also exists in the ambient working tree, so a
/// working-tree read and a PR-revision read of the same request are
/// distinguishable by their text alone.
const FIXTURE_README_BODY: &str = "admin-portal #4526 fixture README\n";

struct IncidentRevisions {
    /// `Carefeed/admin-portal #4526`'s head: has `INCIDENT_PATH`.
    admin_portal: String,
    /// `Carefeed/operations #42`'s head: an ancestor, which does not.
    operations: String,
    /// Kept alive for the whole process — the object store must outlive every
    /// `git show` the daemon runs against it.
    _dir: TempDir,
}

static INCIDENT_REVISIONS: OnceLock<IncidentRevisions> = OnceLock::new();

fn incident_revisions() -> &'static IncidentRevisions {
    INCIDENT_REVISIONS.get_or_init(|| {
        let dir = TempDir::new().unwrap();
        git_ok(dir.path(), &["init", "-q", "-b", "main"]);

        // `Carefeed/operations #42` — thehammer's tailwind fix. No
        // `ContactRecipientService.php` anywhere in it.
        write_file(dir.path(), "tailwind.config.js", "module.exports = {}\n");
        let operations = commit_all(dir.path(), "operations 42");

        // `Carefeed/admin-portal #4526`, as a child so both SHAs live in one
        // object store and both resolve.
        write_file(dir.path(), INCIDENT_PATH, INCIDENT_FILE_BODY);
        write_file(dir.path(), "README.md", FIXTURE_README_BODY);
        let admin_portal = commit_all(dir.path(), "admin-portal 4526");

        // Make these objects readable from the ambient repo the daemon roots
        // its reads at, without writing anything into it. Set exactly once,
        // inside this `OnceLock`, and never unset: it only *adds* an object
        // store, so no other test in this binary can be harmed by it.
        let mut alternates = dir.path().join(".git").join("objects").into_os_string();
        if let Some(existing) = std::env::var_os("GIT_ALTERNATE_OBJECT_DIRECTORIES") {
            alternates.push(":");
            alternates.push(existing);
        }
        std::env::set_var("GIT_ALTERNATE_OBJECT_DIRECTORIES", alternates);

        IncidentRevisions {
            admin_portal,
            operations,
            _dir: dir,
        }
    })
}

/// `git -C <dir> <args>`, panicking with git's stderr on failure. Test setup
/// only — the code under test never uses this.
fn git_ok(dir: &std::path::Path, args: &[&str]) -> std::process::Output {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .expect("git should be on PATH");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out
}

fn write_file(root: &std::path::Path, rel: &str, body: &str) {
    let full = root.join(rel);
    std::fs::create_dir_all(full.parent().unwrap()).unwrap();
    std::fs::write(full, body).unwrap();
}

/// Commit everything with an explicit, ambient-config-independent identity, so
/// this behaves the same on a machine configured to sign commits.
fn commit_all(root: &std::path::Path, message: &str) -> String {
    git_ok(root, &["add", "-A"]);
    git_ok(
        root,
        &[
            "-c",
            "user.email=redd@example.com",
            "-c",
            "user.name=Redd Test",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            message,
        ],
    );
    String::from_utf8(git_ok(root, &["rev-parse", "HEAD"]).stdout)
        .unwrap()
        .trim()
        .to_owned()
}

/// The `(revision, text)` of the one `Code` push a `nostromo.show` of a file
/// produced. Panics if it pushed something else — a file view that landed
/// anything but the file is a failure, not an empty answer.
fn shown_code(bcast: &mut broadcast::Receiver<ServerMsg>) -> (String, String) {
    use nostromo::ipc::protocol::PaneContentWire;
    for (_, _, content) in drained_pane_content(bcast) {
        if let PaneContentWire::Code { revision, text, .. } = content {
            return (revision, text);
        }
    }
    panic!("nostromo.show(file) must broadcast one Code pane content");
}

/// The 2026-09-04 incident, as a regression test.
///
/// Focus A is mid-review of `Carefeed/admin-portal #4526`. Focus B — an
/// ordinary working session that touched a review tool once — picks up
/// `Carefeed/operations #42`. Focus A then asks for a file. Before W7 that
/// request resolved against the daemon-global pin (B's `operations` head) and
/// came back `unknown_path`, with nothing on screen to explain it.
#[tokio::test]
async fn the_2026_09_04_incident_a_file_request_in_focus_a_resolves_in_admin_portal_not_focus_b_s_operations_pr(
) {
    let revs = incident_revisions();
    let harness = make_daemon_state();
    let (_server, socket) = serve(&harness, "incident").await;

    publish_pr(
        &harness.state,
        "focus-a",
        "Carefeed/admin-portal",
        4526,
        &revs.admin_portal,
    );
    publish_pr(
        &harness.state,
        "focus-b",
        "Carefeed/operations",
        42,
        &revs.operations,
    );

    let mut bcast = harness.broadcast_tx.subscribe();
    let (mut ra, mut wa) = connect(&socket, "focus-a").await;
    let res = call_tool_bounded(
        &mut ra,
        &mut wa,
        2,
        "nostromo.show",
        json!({ "type": "file", "target": { "path": INCIDENT_PATH } }),
        Duration::from_secs(10),
    )
    .await;

    assert_eq!(
        res["ok"], true,
        "the file request in focus A must succeed against admin-portal, not come back \
         unknown_path from focus B's operations PR: {res}"
    );

    let (revision, text) = shown_code(&mut bcast);
    assert_eq!(
        revision, revs.admin_portal,
        "the file must be read at focus A's PR head, never at focus B's"
    );
    assert_ne!(
        revision, revs.operations,
        "reading at the other focus's revision is the incident itself"
    );
    assert!(
        text.contains("ContactRecipientService"),
        "and it must be the real file at that revision, got {text:?}"
    );

    // The counter-proof. The very same request, in the focus whose PR really
    // is `operations`, is the `unknown_path` the incident reported — so focus
    // A's success above is isolation working, not the request being
    // unfalsifiable.
    let (mut rb, mut wb) = connect(&socket, "focus-b").await;
    let res = call_tool_bounded(
        &mut rb,
        &mut wb,
        2,
        "nostromo.show",
        json!({ "type": "file", "target": { "path": INCIDENT_PATH } }),
        Duration::from_secs(10),
    )
    .await;
    assert_eq!(
        res["error"], "unknown_path",
        "focus B's PR genuinely does not have this file: {res}"
    );

    // And A is untouched by B's failed request: it still resolves in
    // admin-portal.
    let mut bcast = harness.broadcast_tx.subscribe();
    let res = call_tool_bounded(
        &mut ra,
        &mut wa,
        3,
        "nostromo.show",
        json!({ "type": "file", "target": { "path": INCIDENT_PATH } }),
        Duration::from_secs(10),
    )
    .await;
    assert_eq!(res["ok"], true, "{res}");
    assert_eq!(shown_code(&mut bcast).0, revs.admin_portal);
}

// ── 4. a focus with no PR reads the working tree ─────────────────────────────

/// `README.md` exists both in the ambient working tree and at focus A's PR
/// head, with different content — so the same request in two focuses is
/// answered from two places, and the answer names which.
#[tokio::test]
async fn a_focus_with_no_pr_under_review_reads_the_working_tree_while_another_focus_holds_one() {
    let revs = incident_revisions();
    let harness = make_daemon_state();
    let (_server, socket) = serve(&harness, "working-tree").await;

    publish_pr(
        &harness.state,
        "focus-a",
        "Carefeed/admin-portal",
        4526,
        &revs.admin_portal,
    );
    // focus-c deliberately gets nothing published: it has no PR under review.

    let mut bcast = harness.broadcast_tx.subscribe();
    let (mut rc, mut wc) = connect(&socket, "focus-c").await;
    let res = call_tool_bounded(
        &mut rc,
        &mut wc,
        2,
        "nostromo.show",
        json!({ "type": "file", "target": { "path": "README.md" } }),
        Duration::from_secs(10),
    )
    .await;
    assert_eq!(res["ok"], true, "{res}");

    let (revision, text) = shown_code(&mut bcast);
    assert_eq!(
        revision, "working",
        "a focus with no PR under review reads the working tree, exactly as it did \
         before any focus had one"
    );
    assert!(
        !text.contains(FIXTURE_README_BODY.trim()),
        "and it must be the working tree's file, not the other focus's PR revision"
    );

    // The control: the very same request in the focus that *does* hold a PR
    // resolves at that PR's head instead. One request, two focuses, two
    // correct and different answers.
    let mut bcast = harness.broadcast_tx.subscribe();
    let (mut ra, mut wa) = connect(&socket, "focus-a").await;
    let res = call_tool_bounded(
        &mut ra,
        &mut wa,
        2,
        "nostromo.show",
        json!({ "type": "file", "target": { "path": "README.md" } }),
        Duration::from_secs(10),
    )
    .await;
    assert_eq!(res["ok"], true, "{res}");
    let (revision, text) = shown_code(&mut bcast);
    assert_eq!(revision, revs.admin_portal);
    assert!(text.contains(FIXTURE_README_BODY.trim()));
}

// ── 5. no cross-focus mutation ───────────────────────────────────────────────

/// "No call made in one focus changes what any other focus reports as under
/// review. This holds for picking up a PR, clearing one, and any other
/// operation that moves it."
#[tokio::test]
async fn a_pickup_or_a_clear_in_one_focus_leaves_every_other_focus_s_pin_byte_identical() {
    let harness = make_daemon_state();
    let (_server, socket) = serve(&harness, "no-cross-mutation").await;

    let (mut ra, mut wa) = connect(&socket, "focus-a").await;
    let (mut rb, mut wb) = connect(&socket, "focus-b").await;
    let (mut rc, mut wc) = connect(&socket, "focus-c").await;

    for (reader, writer, repo, number) in [
        (&mut ra, &mut wa, "Carefeed/admin-portal", 4526u64),
        (&mut rb, &mut wb, "Carefeed/operations", 42),
        (&mut rc, &mut wc, "Carefeed/admin-portal", 4530),
    ] {
        let res = call_tool_bounded(
            reader,
            writer,
            2,
            "perri.load_pr",
            json!({ "number": number, "repo": repo, "highlights": "seed" }),
            BOUND,
        )
        .await;
        assert_eq!(res["ok"], true, "{res}");
    }
    publish_pr(
        &harness.state,
        "focus-a",
        "Carefeed/admin-portal",
        4526,
        "sha-a",
    );
    publish_pr(
        &harness.state,
        "focus-b",
        "Carefeed/operations",
        42,
        "sha-b",
    );
    publish_pr(
        &harness.state,
        "focus-c",
        "Carefeed/admin-portal",
        4530,
        "sha-c",
    );

    let b_pin_before = pin_bytes(&harness, "focus-b").expect("focus B picked one up");
    let c_pin_before = pin_bytes(&harness, "focus-c").expect("focus C picked one up");
    let b_reported_before = call_tool_bounded(
        &mut rb,
        &mut wb,
        3,
        "perri.get_current_pr",
        json!({}),
        BOUND,
    )
    .await;
    let c_reported_before = call_tool_bounded(
        &mut rc,
        &mut wc,
        3,
        "perri.get_current_pr",
        json!({}),
        BOUND,
    )
    .await;

    // Focus A moves its review twice: onto a different PR, then off entirely.
    // Both are the operations the PRD names.
    let res = call_tool_bounded(
        &mut ra,
        &mut wa,
        4,
        "perri.load_pr",
        json!({ "number": 999, "repo": "Carefeed/portal", "highlights": "moved" }),
        BOUND,
    )
    .await;
    assert_eq!(res["ok"], true, "{res}");
    // The native source would follow A's pin; simulate that so this test is
    // not quietly asserting that *nothing anywhere* changed.
    publish_pr(&harness.state, "focus-a", "Carefeed/portal", 999, "sha-a2");
    assert_eq!(pinned(&harness, "focus-a"), ("Carefeed/portal".into(), 999));

    let res = call_tool_bounded(
        &mut ra,
        &mut wa,
        5,
        "perri.clear_current_pr",
        json!({}),
        BOUND,
    )
    .await;
    assert_eq!(res["ok"], true, "{res}");
    harness.state.clear_pr_for("focus-a");
    assert!(
        pin_bytes(&harness, "focus-a").is_none(),
        "A's own pin is gone, which is the only thing A's clear may do"
    );

    assert_eq!(
        pin_bytes(&harness, "focus-b").as_deref(),
        Some(b_pin_before.as_slice()),
        "focus B's pin file must be byte-identical after A picked up and cleared"
    );
    assert_eq!(
        pin_bytes(&harness, "focus-c").as_deref(),
        Some(c_pin_before.as_slice()),
        "and so must focus C's"
    );

    let b_reported_after = call_tool_bounded(
        &mut rb,
        &mut wb,
        6,
        "perri.get_current_pr",
        json!({}),
        BOUND,
    )
    .await;
    let c_reported_after = call_tool_bounded(
        &mut rc,
        &mut wc,
        6,
        "perri.get_current_pr",
        json!({}),
        BOUND,
    )
    .await;
    assert_eq!(
        serde_json::to_string(&b_reported_after).unwrap(),
        serde_json::to_string(&b_reported_before).unwrap(),
        "what focus B reports as under review must be byte-identical"
    );
    assert_eq!(
        serde_json::to_string(&c_reported_after).unwrap(),
        serde_json::to_string(&c_reported_before).unwrap(),
        "and so must focus C's"
    );
    // …and A really did move, so the equalities above are not vacuous.
    let a_reported = call_tool_bounded(
        &mut ra,
        &mut wa,
        7,
        "perri.get_current_pr",
        json!({}),
        BOUND,
    )
    .await;
    assert!(
        a_reported.is_null(),
        "focus A cleared its own review and must report none: {a_reported}"
    );
}

// ── 6. the queue stays fleet-wide ────────────────────────────────────────────

/// Seed a live PR queue. Must run before the server binds: `McpServer::bind`
/// takes a clone of the state, and a `watch::Receiver` is a value, not a
/// handle to a slot.
fn seed_queue(harness: &mut Harness, items: Value) {
    let snapshot: nostromo::data::perri_queue::PrQueueSnapshot = serde_json::from_value(json!({
        "generated_at": null, "items": items, "stale": false, "error": null
    }))
    .unwrap();
    let (_tx, rx) = tokio::sync::watch::channel(Some(snapshot));
    harness.state.perri_queue_rx = rx;
}

fn queue_fixture() -> Value {
    json!([
        {
            "repo": "Carefeed/admin-portal", "number": 4526, "title": "Recipients",
            "author": "hammer", "url": "https://example.com/4526"
        },
        {
            "repo": "Carefeed/operations", "number": 42, "title": "Tailwind",
            "author": "thehammer", "url": "https://example.com/42"
        }
    ])
}

#[tokio::test]
async fn every_focus_sees_the_same_pr_queue_and_a_pickup_in_one_focus_changes_nobody_s() {
    let mut harness = make_daemon_state();
    seed_queue(&mut harness, queue_fixture());
    let (_server, socket) = serve(&harness, "fleet-queue").await;

    let (mut ra, mut wa) = connect(&socket, "focus-a").await;
    let (mut rb, mut wb) = connect(&socket, "focus-b").await;

    let a_before =
        call_tool_bounded(&mut ra, &mut wa, 2, "perri.list_pr_queue", json!({}), BOUND).await;
    let b_before =
        call_tool_bounded(&mut rb, &mut wb, 2, "perri.list_pr_queue", json!({}), BOUND).await;
    assert_eq!(
        a_before.as_array().map(Vec::len),
        Some(2),
        "the seeded queue must actually reach the tool: {a_before}"
    );
    assert_eq!(
        a_before, b_before,
        "one set of open PRs exists; every focus sees the same one"
    );

    // A pickup in focus A — the operation that is per-focus.
    let res = call_tool_bounded(
        &mut ra,
        &mut wa,
        3,
        "perri.load_pr",
        json!({ "number": 4526, "repo": "Carefeed/admin-portal", "highlights": "x" }),
        BOUND,
    )
    .await;
    assert_eq!(res["ok"], true, "{res}");
    publish_pr(
        &harness.state,
        "focus-a",
        "Carefeed/admin-portal",
        4526,
        "sha-a",
    );

    let a_after =
        call_tool_bounded(&mut ra, &mut wa, 4, "perri.list_pr_queue", json!({}), BOUND).await;
    let b_after =
        call_tool_bounded(&mut rb, &mut wb, 4, "perri.list_pr_queue", json!({}), BOUND).await;
    assert_eq!(a_after, a_before, "the picker's own queue is unchanged");
    assert_eq!(
        b_after, b_before,
        "and no other focus's queue moved either — only the PR under review is scoped"
    );

    // The composite state query carries the same fleet-wide queue for both.
    let a_state = call_tool_bounded(&mut ra, &mut wa, 5, "perri.get_state", json!({}), BOUND).await;
    let b_state = call_tool_bounded(&mut rb, &mut wb, 5, "perri.get_state", json!({}), BOUND).await;
    assert_eq!(a_state["queue"], b_state["queue"]);
    assert_eq!(a_state["queue"], a_before);
    assert_eq!(
        a_state["current_pr"]["pr_number"], 4526,
        "while the *review* half of the same response is A's alone: {a_state}"
    );
    assert!(
        b_state["current_pr"].is_null(),
        "and B, who picked nothing up, still has none: {b_state}"
    );
}

// ── 7. an explicit view_id drives that focus ─────────────────────────────────

#[tokio::test]
async fn an_explicit_view_id_drives_that_focus_even_when_the_caller_is_a_different_one() {
    let harness = make_daemon_state();
    let (_server, socket) = serve(&harness, "explicit-view-id").await;

    // The caller's Hello names focus-a; the call names focus-b. The explicit
    // `view_id` wins — the daemon's one addressing rule, which every other
    // focus-scoped tool already follows.
    let (mut ra, mut wa) = connect(&socket, "focus-a").await;
    let res = call_tool_bounded(
        &mut ra,
        &mut wa,
        2,
        "perri.load_pr",
        json!({
            "number": 4526, "repo": "Carefeed/admin-portal",
            "highlights": "for B", "view_id": "focus-b"
        }),
        BOUND,
    )
    .await;
    assert_eq!(res["ok"], true, "{res}");

    assert_eq!(
        pinned(&harness, "focus-b"),
        ("Carefeed/admin-portal".into(), 4526),
        "the named focus is the one whose review moved"
    );
    assert!(
        pin_bytes(&harness, "focus-a").is_none(),
        "and the *calling* focus picked up nothing at all"
    );

    publish_pr(
        &harness.state,
        "focus-b",
        "Carefeed/admin-portal",
        4526,
        "sha-b",
    );

    // Reads honour it the same way, from the same foreign caller.
    let named = call_tool_bounded(
        &mut ra,
        &mut wa,
        3,
        "perri.get_current_pr",
        json!({ "view_id": "focus-b" }),
        BOUND,
    )
    .await;
    assert_eq!(named["pr_number"], 4526);
    assert_eq!(named["repo"], "Carefeed/admin-portal");

    let own = call_tool_bounded(
        &mut ra,
        &mut wa,
        4,
        "perri.get_current_pr",
        json!({}),
        BOUND,
    )
    .await;
    assert!(
        own.is_null(),
        "naming no focus still means the caller's own, which has none: {own}"
    );

    // And a clear aimed at the named focus clears that one, not the caller's.
    publish_pr(&harness.state, "focus-a", "Carefeed/portal", 1, "sha-a");
    let res = call_tool_bounded(
        &mut ra,
        &mut wa,
        5,
        "perri.clear_current_pr",
        json!({ "view_id": "focus-b" }),
        BOUND,
    )
    .await;
    assert_eq!(res["ok"], true, "{res}");
    assert!(
        pin_bytes(&harness, "focus-b").is_none(),
        "the named focus's pin is the one that went"
    );
}

// ── 8. get_state's empty cases are present keys, never absent ones ───────────

/// "Both are present when empty, stated explicitly, never as an absent key."
/// An absent key reads as "this daemon doesn't support it", which is a
/// different and wrong answer from "there is none" — and they are different on
/// the wire, so this is asserted on key *presence*, not on the value.
#[tokio::test]
async fn get_state_states_its_empty_cases_explicitly_rather_than_omitting_the_keys() {
    let harness = make_daemon_state();
    let (_server, socket) = serve(&harness, "empty-state").await;

    let (mut ra, mut wa) = connect(&socket, "focus-a").await;
    let res = call_tool_bounded(&mut ra, &mut wa, 2, "perri.get_state", json!({}), BOUND).await;
    let obj = res.as_object().expect("get_state returns an object");

    assert!(
        obj.contains_key("current_pr"),
        "`current_pr` must be present even when there is none: {res}"
    );
    assert!(res["current_pr"].is_null(), "…and explicitly null: {res}");
    assert!(
        obj.contains_key("other_focuses"),
        "`other_focuses` must be present even when no other focus has one: {res}"
    );
    assert_eq!(
        res["other_focuses"],
        json!([]),
        "…and explicitly the empty list: {res}"
    );

    // The same holds for a caller with no PR while another focus has one —
    // the empty half must not start being omitted just because the response
    // now has something else in it.
    publish_pr(
        &harness.state,
        "focus-b",
        "Carefeed/operations",
        42,
        "sha-b",
    );
    let res = call_tool_bounded(&mut ra, &mut wa, 3, "perri.get_state", json!({}), BOUND).await;
    let obj = res.as_object().unwrap();
    assert!(obj.contains_key("current_pr"), "{res}");
    assert!(res["current_pr"].is_null(), "{res}");
    assert_eq!(
        res["other_focuses"].as_array().map(Vec::len),
        Some(1),
        "{res}"
    );

    // And the mirror: a caller that *has* one, with nobody else holding any.
    let harness = make_daemon_state();
    let (_server, socket) = serve(&harness, "empty-others").await;
    publish_pr(
        &harness.state,
        "focus-a",
        "Carefeed/admin-portal",
        4526,
        "sha-a",
    );
    let (mut ra, mut wa) = connect(&socket, "focus-a").await;
    let res = call_tool_bounded(&mut ra, &mut wa, 2, "perri.get_state", json!({}), BOUND).await;
    let obj = res.as_object().unwrap();
    assert_eq!(res["current_pr"]["pr_number"], 4526, "{res}");
    assert!(
        obj.contains_key("other_focuses"),
        "`other_focuses` stays present when the caller is the only holder: {res}"
    );
    assert_eq!(res["other_focuses"], json!([]), "{res}");
}

// ── 9. other_focuses is the fleet read, minus the caller ─────────────────────

#[tokio::test]
async fn other_focuses_reports_every_other_focus_s_pr_and_never_the_caller_s_own() {
    let harness = make_daemon_state();
    let (_server, socket) = serve(&harness, "other-focuses").await;

    publish_pr(
        &harness.state,
        "focus-a",
        "Carefeed/admin-portal",
        4526,
        "sha-a",
    );
    publish_pr(
        &harness.state,
        "focus-b",
        "Carefeed/operations",
        42,
        "sha-b",
    );
    publish_pr(
        &harness.state,
        "focus-c",
        "Carefeed/admin-portal",
        4530,
        "sha-c",
    );

    let (mut ra, mut wa) = connect(&socket, "focus-a").await;
    let res = call_tool_bounded(&mut ra, &mut wa, 2, "perri.get_state", json!({}), BOUND).await;

    assert_eq!(
        res["other_focuses"],
        json!([
            { "tag": "focus-b", "repo": "Carefeed/operations", "number": 42 },
            { "tag": "focus-c", "repo": "Carefeed/admin-portal", "number": 4530 },
        ]),
        "the fleet read is every *other* focus's {{tag, repo, number}}, sorted by tag \
         so the answer is stable between calls: {res}"
    );
    let tags: Vec<&str> = res["other_focuses"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["tag"].as_str().unwrap())
        .collect();
    assert!(
        !tags.contains(&"focus-a"),
        "the caller's own review is `current_pr`, never an entry in `other_focuses`: {res}"
    );
    assert_eq!(res["current_pr"]["pr_number"], 4526, "{res}");

    // Every focus gets the same fleet read, minus itself.
    let (mut rb, mut wb) = connect(&socket, "focus-b").await;
    let res = call_tool_bounded(&mut rb, &mut wb, 2, "perri.get_state", json!({}), BOUND).await;
    assert_eq!(
        res["other_focuses"],
        json!([
            { "tag": "focus-a", "repo": "Carefeed/admin-portal", "number": 4526 },
            { "tag": "focus-c", "repo": "Carefeed/admin-portal", "number": 4530 },
        ]),
        "{res}"
    );

    // A focus with no PR under review is not "a focus holding none" — it is
    // simply absent from the list.
    let (mut rd, mut wd) = connect(&socket, "focus-d").await;
    let res = call_tool_bounded(&mut rd, &mut wd, 2, "perri.get_state", json!({}), BOUND).await;
    assert_eq!(
        res["other_focuses"].as_array().map(Vec::len),
        Some(3),
        "{res}"
    );
    assert!(res["current_pr"].is_null(), "{res}");
}

// ── 10. NO GATE, EVER ────────────────────────────────────────────────────────

/// A hard PRD criterion guarding a rejected design (the negotiated handoff):
/// "Picking up a PR succeeds unconditionally in every collision case: no
/// prompt, no confirmation, no block, no wait, no refusal."
///
/// Asserted positively rather than as "the call returned ok": a gate in this
/// daemon is a `nostromo.ask_decision`-style submission into the
/// `DecisionRegistry` plus a `ServerMsg::DecisionRequest` on the wire, so both
/// are checked to be empty. A handoff prompt arriving through the back door
/// would show up in exactly those two places.
#[tokio::test]
async fn picking_up_a_pr_raises_no_decision_in_any_collision_permutation() {
    /// One collision shape: what focus B already holds when focus A picks up.
    struct Collision {
        held_by_b: Option<(&'static str, u64)>,
        picked_up_by_a: (&'static str, u64),
    }

    // Every collision shape the old singleton could produce, plus the
    // no-collision baseline so the assertions below are anchored.
    let permutations = [
        // Nobody else holds anything.
        Collision {
            held_by_b: None,
            picked_up_by_a: ("Carefeed/admin-portal", 4526),
        },
        // A different PR in a different repo — the recorded incident's shape.
        Collision {
            held_by_b: Some(("Carefeed/operations", 42)),
            picked_up_by_a: ("Carefeed/admin-portal", 4526),
        },
        // A different PR in the *same* repo.
        Collision {
            held_by_b: Some(("Carefeed/admin-portal", 4530)),
            picked_up_by_a: ("Carefeed/admin-portal", 4526),
        },
        // The very same PR, in the same repo — the one case that gets an
        // advisory and still must not get a gate.
        Collision {
            held_by_b: Some(("Carefeed/admin-portal", 4526)),
            picked_up_by_a: ("Carefeed/admin-portal", 4526),
        },
        // The same number in a different repo.
        Collision {
            held_by_b: Some(("Carefeed/operations", 4526)),
            picked_up_by_a: ("Carefeed/admin-portal", 4526),
        },
    ];

    for Collision {
        held_by_b,
        picked_up_by_a: (repo, number),
    } in permutations
    {
        let harness = make_daemon_state();
        let (_server, socket) = serve(&harness, "no-gate").await;
        let mut bcast = harness.broadcast_tx.subscribe();

        if let Some((b_repo, b_number)) = held_by_b {
            let (mut rb, mut wb) = connect(&socket, "focus-b").await;
            let res = call_tool_bounded(
                &mut rb,
                &mut wb,
                2,
                "perri.load_pr",
                json!({ "number": b_number, "repo": b_repo, "highlights": "held" }),
                BOUND,
            )
            .await;
            assert_eq!(
                res["ok"], true,
                "seeding focus B must itself not be gated: {res}"
            );
            publish_pr(&harness.state, "focus-b", b_repo, b_number, "sha-b");
        }

        let (mut ra, mut wa) = connect(&socket, "focus-a").await;
        // Twice: a focus that already holds this PR picking it up again is
        // itself a collision permutation, and must be as ungated as the first.
        for id in [2i64, 3] {
            let res = call_tool_bounded(
                &mut ra,
                &mut wa,
                id,
                "perri.load_pr",
                json!({ "number": number, "repo": repo, "highlights": "mine" }),
                BOUND,
            )
            .await;
            assert_eq!(
                res["ok"], true,
                "pickup of {repo}#{number} while B holds {held_by_b:?} must succeed: {res}"
            );
            assert!(
                res.get("error").is_none(),
                "…with no refusal of any kind: {res}"
            );
        }

        // The positive half: nothing was ever asked of the operator.
        {
            let reg = harness.decisions.lock().unwrap();
            for tag in ["focus-a", "focus-b"] {
                assert_eq!(
                    reg.active_request_id(tag),
                    None,
                    "a pickup must raise no decision for {tag} (B held {held_by_b:?})"
                );
                assert_eq!(
                    reg.queued_count(tag),
                    0,
                    "and queue none behind one either, for {tag}"
                );
            }
        }
        let mut decisions_on_the_wire = 0;
        while let Ok(msg) = bcast.try_recv() {
            if matches!(msg, ServerMsg::DecisionRequest { .. }) {
                decisions_on_the_wire += 1;
            }
        }
        assert_eq!(
            decisions_on_the_wire, 0,
            "no DecisionRequest may reach any client for a pickup (B held {held_by_b:?})"
        );

        // …and the pickup actually took, so "ungated" is not "ignored".
        assert_eq!(pinned(&harness, "focus-a"), (repo.to_owned(), number));
        if let Some((b_repo, b_number)) = held_by_b {
            assert_eq!(
                pinned(&harness, "focus-b"),
                (b_repo.to_owned(), b_number),
                "and B kept what it had: A's pickup took nothing from anyone"
            );
        }
    }
}

/// The same criterion as the incident test, for the review's other two
/// surfaces: "a file, **diff**, or **conversation** requested in focus A
/// resolves against A's PR". Neither of these touches git, so they say it
/// directly — the content that lands on the wire names the PR it came from.
#[tokio::test]
async fn a_diff_or_conversation_shown_in_one_focus_carries_that_focus_s_pr_and_no_other_s() {
    use nostromo::ipc::protocol::PaneContentWire;

    let harness = make_daemon_state();
    let (_server, socket) = serve(&harness, "diff-and-conversation").await;

    publish_pr(
        &harness.state,
        "focus-a",
        "Carefeed/admin-portal",
        4526,
        "sha-a",
    );
    publish_pr(
        &harness.state,
        "focus-b",
        "Carefeed/operations",
        42,
        "sha-b",
    );

    for (tag, repo, number) in [
        ("focus-a", "Carefeed/admin-portal", 4526u64),
        ("focus-b", "Carefeed/operations", 42),
    ] {
        let (mut r, mut w) = connect(&socket, tag).await;

        let mut bcast = harness.broadcast_tx.subscribe();
        let res = call_tool_bounded(
            &mut r,
            &mut w,
            2,
            "nostromo.show",
            json!({ "type": "pr_diff", "target": { "repo": repo, "number": number } }),
            Duration::from_secs(5),
        )
        .await;
        assert_eq!(res["ok"], true, "{tag}: {res}");
        let diff = drained_pane_content(&mut bcast)
            .into_iter()
            .find_map(|(_, _, c)| match c {
                PaneContentWire::Diff { repo, number, .. } => Some((repo, number)),
                _ => None,
            })
            .unwrap_or_else(|| panic!("{tag} must get a Diff pane"));
        assert_eq!(
            diff,
            (repo.to_owned(), Some(number)),
            "{tag}'s diff must be {tag}'s own PR"
        );

        let mut bcast = harness.broadcast_tx.subscribe();
        let res = call_tool_bounded(
            &mut r,
            &mut w,
            3,
            "nostromo.show",
            json!({ "type": "pr_conversation", "target": { "repo": repo, "number": number } }),
            Duration::from_secs(5),
        )
        .await;
        assert_eq!(res["ok"], true, "{tag}: {res}");
        let convo = drained_pane_content(&mut bcast)
            .into_iter()
            .find_map(|(_, _, c)| match c {
                PaneContentWire::PrConversation { repo, number, .. } => Some((repo, number)),
                _ => None,
            })
            .unwrap_or_else(|| panic!("{tag} must get a PrConversation pane"));
        assert_eq!(
            convo,
            (repo.to_owned(), Some(number)),
            "{tag}'s conversation must be {tag}'s own PR"
        );
    }
}
