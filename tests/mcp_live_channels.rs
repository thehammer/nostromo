//! Live data channels under the **daemon-hosted** MCP server: Teri, Fred,
//! Mother status / views, and Mother's job-control mutators.
//!
//! Every test drives the real Unix-socket MCP server over a daemon-hosted
//! `McpSharedState` built with `for_daemon_with_sources`, keeping the senders
//! of the watch channels so a test can publish a snapshot exactly as a native
//! source would. Mother's mutators shell out to the `mother` CLI named by the
//! `MOTHER_BIN` env var; tests point that at a fake script that records its
//! argv.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::data::fred_calendar::CalendarSnapshot;
use nostromo::data::fred_mailbox::MailboxSnapshot;
use nostromo::data::perri_queue::PrQueueSnapshot;
use nostromo::data::teri_todos::TeriTodosSnapshot;
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::SessionManager;
use nostromo::mcp::{
    DaemonMcpBackend, DaemonSources, McpServer, McpSharedState, PerriDaemonState,
};
use nostromo::mother::MotherJob;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, watch};

const BOUND: Duration = Duration::from_secs(3);

// ── harness ───────────────────────────────────────────────────────────────────

struct Harness {
    dir: TempDir,
    server: McpServer,
    socket: PathBuf,
    broadcast_tx: broadcast::Sender<ServerMsg>,
    queue_tx: watch::Sender<Option<PrQueueSnapshot>>,
    jobs_tx: watch::Sender<Vec<MotherJob>>,
    mailbox_tx: watch::Sender<Option<MailboxSnapshot>>,
    calendar_tx: watch::Sender<Option<CalendarSnapshot>>,
    todos_tx: watch::Sender<Option<TeriTodosSnapshot>>,
}

/// A daemon whose every source starts as "nothing published yet".
async fn harness() -> Harness {
    let dir = TempDir::new().unwrap();
    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        dir.path().join("panes.json"),
    )));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        dir.path().join("sessions.json"),
    )));
    let (broadcast_tx, _rx) = broadcast::channel::<ServerMsg>(64);
    let backend = DaemonMcpBackend {
        pane_registry,
        session_mgr,
        broadcast_tx: broadcast_tx.clone(),
        perri: PerriDaemonState {
            state_dir: Some(dir.path().join("perri-state")),
            pr_refresh_tx: None,
            queue_refresh_tx: None,
            selected_index: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            settle_timeout: Duration::from_millis(100),
        },
        decisions: Arc::new(Mutex::new(
            nostromo::ipc::decisions::DecisionRegistry::default(),
        )),
        tickets: Default::default(),
    };
    let (queue_tx, queue_rx) = watch::channel(None);
    let (_pr_tx, pr_rx) = watch::channel(nostromo::data::perri_pr::no_prs());
    let (jobs_tx, jobs_rx) = watch::channel(Vec::new());
    let (mailbox_tx, mailbox_rx) = watch::channel(None);
    let (calendar_tx, calendar_rx) = watch::channel(None);
    let (todos_tx, todos_rx) = watch::channel(None);
    // Keep the PR sender alive for the process: a dropped sender is a verdict.
    std::mem::forget(_pr_tx);

    let state = McpSharedState::for_daemon_with_sources(
        backend,
        DaemonSources {
            perri_queue_rx: queue_rx,
            perri_pr_rx: pr_rx,
            mother_jobs_rx: jobs_rx,
            fred_mailbox_rx: mailbox_rx,
            fred_calendar_rx: calendar_rx,
            teri_todos_rx: todos_rx,
        },
    );
    let socket = dir.path().join("mcp.sock");
    let server = McpServer::bind(socket.clone(), state)
        .await
        .expect("server should bind");
    Harness {
        dir,
        server,
        socket,
        broadcast_tx,
        queue_tx,
        jobs_tx,
        mailbox_tx,
        calendar_tx,
        todos_tx,
    }
}

struct Client {
    reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: tokio::net::unix::OwnedWriteHalf,
    next_id: i64,
}

impl Client {
    async fn connect(h: &Harness) -> Client {
        let stream = UnixStream::connect(&h.socket).await.unwrap();
        let (r, mut writer) = stream.into_split();
        let mut reader = BufReader::new(r);
        send(&mut writer, &json!({"type":"hello","pty_id":"teri"})).await;
        send(
            &mut writer,
            &json!({
                "jsonrpc":"2.0","id":1,"method":"initialize",
                "params":{"protocolVersion":"2024-11-05","capabilities":{},
                          "clientInfo":{"name":"t","version":"0"}}
            }),
        )
        .await;
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        Client {
            reader,
            writer,
            next_id: 2,
        }
    }

    /// `tools/call`, returning the parsed tool-content JSON.
    async fn call(&mut self, name: &str, args: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        send(
            &mut self.writer,
            &json!({"jsonrpc":"2.0","id":id,"method":"tools/call",
                    "params":{"name":name,"arguments":args}}),
        )
        .await;
        let mut line = String::new();
        tokio::time::timeout(BOUND, self.reader.read_line(&mut line))
            .await
            .unwrap_or_else(|_| panic!("{name} did not respond within {BOUND:?}"))
            .unwrap();
        let resp: Value = serde_json::from_str(line.trim()).expect("response is JSON");
        assert!(resp.get("error").is_none(), "{name} JSON-RPC error: {resp}");
        let text = resp["result"]["content"][0]["text"].as_str().unwrap();
        serde_json::from_str(text).expect("tool content should be JSON")
    }
}

async fn send<W: AsyncWriteExt + Unpin>(w: &mut W, v: &Value) {
    let mut bytes = serde_json::to_vec(v).unwrap();
    bytes.push(b'\n');
    w.write_all(&bytes).await.unwrap();
}

// ── fixtures ──────────────────────────────────────────────────────────────────

fn todos(items: usize, stale: bool, error: Option<&str>) -> TeriTodosSnapshot {
    serde_json::from_value(json!({
        "generated_at": "2026-10-09T15:00:00Z",
        "items": (1..=items).map(|i| json!({
            "id": i, "title": format!("todo {i}"), "status": "open",
            "priority": 2, "due_date": null, "jira_key": null
        })).collect::<Vec<_>>(),
        "stale": stale,
        "error": error,
    }))
    .unwrap()
}

fn mailbox(unread: usize, stale: bool, error: Option<&str>, auth: bool) -> MailboxSnapshot {
    serde_json::from_value(json!({
        "generated_at": "2026-10-09T15:00:00Z",
        "unread_count": unread,
        "items": (0..unread).map(|i| json!({
            "from": "a@example.com", "subject": format!("mail {i}"),
            "received_at": null, "vip": false, "is_invite": false, "is_read": false
        })).collect::<Vec<_>>(),
        "stale": stale,
        "error": error,
        "auth_prompt": if auth { json!({
            "verification_uri": "https://microsoft.com/devicelogin",
            "user_code": "ABCD-1234",
            "expires_at": "2026-10-09T16:00:00Z"
        }) } else { Value::Null },
    }))
    .unwrap()
}

fn calendar(events: usize, stale: bool, error: Option<&str>) -> CalendarSnapshot {
    serde_json::from_value(json!({
        "events": (0..events).map(|i| json!({
            "start": "2026-10-09T17:00:00Z", "end": "2026-10-09T18:00:00Z",
            "title": format!("event {i}"), "status": "busy", "is_now": false
        })).collect::<Vec<_>>(),
        "next": null, "sweater": "sage",
        "stale": stale, "error": error,
    }))
    .unwrap()
}

fn job(id: &str, state: &str) -> MotherJob {
    serde_json::from_value(json!({ "id": id, "state": state })).unwrap()
}

// ═════════════════════════════════════════════════════════════════════════════
// Teri
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn teri_list_todos_before_any_snapshot_says_loading_not_empty() {
    let h = harness().await;
    let mut c = Client::connect(&h).await;
    let res = c.call("teri.list_todos", json!({})).await;
    assert_eq!(res["state"], "loading", "{res}");
}

#[tokio::test]
async fn teri_list_todos_with_items_is_fresh_and_carries_the_items_and_timestamp() {
    let h = harness().await;
    h.todos_tx.send(Some(todos(2, false, None))).unwrap();
    let mut c = Client::connect(&h).await;
    let res = c.call("teri.list_todos", json!({})).await;
    assert_eq!(res["state"], "fresh", "{res}");
    assert_eq!(res["items"].as_array().map(Vec::len), Some(2), "{res}");
    assert_eq!(res["updated_at"], res["generated_at"], "{res}");
    assert!(res["updated_at"].is_string(), "{res}");
    assert!(res.get("reason").is_none() || res["reason"].is_null(), "{res}");
}

#[tokio::test]
async fn teri_list_todos_with_no_items_is_empty() {
    let h = harness().await;
    h.todos_tx.send(Some(todos(0, false, None))).unwrap();
    let mut c = Client::connect(&h).await;
    let res = c.call("teri.list_todos", json!({})).await;
    assert_eq!(res["state"], "empty", "{res}");
}

#[tokio::test]
async fn teri_list_todos_failure_is_an_error_with_a_reason_not_an_empty_success() {
    let h = harness().await;
    h.todos_tx
        .send(Some(todos(0, false, Some("db locked"))))
        .unwrap();
    let mut c = Client::connect(&h).await;
    let res = c.call("teri.list_todos", json!({})).await;
    assert_eq!(res["state"], "error", "{res}");
    assert_eq!(res["reason"], "db locked", "{res}");
    assert_eq!(res["items"].as_array().map(Vec::len), Some(0), "{res}");
}

#[tokio::test]
async fn teri_list_todos_serving_old_data_after_a_failed_refresh_is_stale() {
    let h = harness().await;
    h.todos_tx
        .send(Some(todos(2, true, Some("db locked"))))
        .unwrap();
    let mut c = Client::connect(&h).await;
    let res = c.call("teri.list_todos", json!({})).await;
    assert_eq!(res["state"], "stale", "{res}");
    assert_eq!(res["reason"], "db locked", "{res}");
    assert_eq!(res["items"].as_array().map(Vec::len), Some(2), "{res}");
}

#[tokio::test]
async fn teri_list_todos_reflects_a_later_snapshot_on_the_same_connection() {
    let h = harness().await;
    let mut c = Client::connect(&h).await;
    assert_eq!(c.call("teri.list_todos", json!({})).await["state"], "loading");
    h.todos_tx.send(Some(todos(1, false, None))).unwrap();
    let res = c.call("teri.list_todos", json!({})).await;
    assert_eq!(res["state"], "fresh", "{res}");
}

// ═════════════════════════════════════════════════════════════════════════════
// Fred
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn fred_tools_before_any_snapshot_say_loading_never_a_bare_zero_or_empty_array() {
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    let unread = c.call("fred.list_unread_emails", json!({})).await;
    assert!(unread.is_object(), "must be an object, not a bare array: {unread}");
    assert_eq!(unread["state"], "loading", "{unread}");

    let cal = c.call("fred.list_calendar_events", json!({})).await;
    assert!(cal.is_object(), "must be an object, not a bare array: {cal}");
    assert_eq!(cal["state"], "loading", "{cal}");

    let st = c.call("fred.get_state", json!({})).await;
    assert_eq!(st["state"], "loading", "{st}");
    assert_eq!(st["mailbox_state"], "loading", "{st}");
    assert_eq!(st["calendar_state"], "loading", "{st}");
}

#[tokio::test]
async fn fred_list_unread_emails_returns_state_count_and_items() {
    let h = harness().await;
    h.mailbox_tx.send(Some(mailbox(3, false, None, false))).unwrap();
    let mut c = Client::connect(&h).await;
    let res = c.call("fred.list_unread_emails", json!({})).await;
    assert_eq!(res["state"], "fresh", "{res}");
    assert_eq!(res["unread_count"], 3, "{res}");
    assert_eq!(res["items"].as_array().map(Vec::len), Some(3), "{res}");
    assert!(res["updated_at"].is_string(), "{res}");
}

#[tokio::test]
async fn fred_mailbox_error_with_no_items_is_an_error_not_unread_zero_alone() {
    let h = harness().await;
    h.mailbox_tx
        .send(Some(mailbox(0, false, Some("graph 503"), false)))
        .unwrap();
    let mut c = Client::connect(&h).await;

    let res = c.call("fred.list_unread_emails", json!({})).await;
    assert_eq!(res["state"], "error", "{res}");
    assert_eq!(res["reason"], "graph 503", "{res}");

    let st = c.call("fred.get_state", json!({})).await;
    assert_eq!(st["mailbox_state"], "error", "{st}");
    assert_eq!(st["state"], "error", "{st}");
    assert_eq!(st["reason"], "graph 503", "{st}");
}

#[tokio::test]
async fn fred_mailbox_needing_sign_in_is_unauthenticated_with_the_device_code_prompt() {
    let h = harness().await;
    h.mailbox_tx.send(Some(mailbox(0, false, None, true))).unwrap();
    h.calendar_tx.send(Some(calendar(1, false, None))).unwrap();
    let mut c = Client::connect(&h).await;

    let st = c.call("fred.get_state", json!({})).await;
    assert_eq!(st["state"], "unauthenticated", "{st}");
    assert_eq!(st["mailbox_state"], "unauthenticated", "{st}");
    assert_eq!(st["auth"]["verification_uri"], "https://microsoft.com/devicelogin");
    assert_eq!(st["auth"]["user_code"], "ABCD-1234");
    assert!(st["auth"]["expires_at"].is_string(), "{st}");

    let unread = c.call("fred.list_unread_emails", json!({})).await;
    assert_eq!(unread["state"], "unauthenticated", "{unread}");
    assert_eq!(unread["auth"]["user_code"], "ABCD-1234", "{unread}");
}

#[tokio::test]
async fn fred_overall_state_is_the_worst_of_mailbox_and_calendar() {
    // (mailbox, calendar, expected overall) — rank: unauthenticated > error >
    // stale > loading > fresh/empty.
    type Case = (Option<MailboxSnapshot>, Option<CalendarSnapshot>, &'static str);
    let cases: Vec<Case> = vec![
        (
            Some(mailbox(1, false, None, false)),
            Some(calendar(1, false, Some("cal down"))),
            "error",
        ),
        (
            Some(mailbox(1, true, Some("slow"), false)),
            Some(calendar(1, false, None)),
            "stale",
        ),
        (Some(mailbox(1, false, None, false)), None, "loading"),
        (
            Some(mailbox(1, false, None, false)),
            Some(calendar(1, false, None)),
            "fresh",
        ),
        (
            Some(mailbox(0, false, Some("boom"), false)),
            Some(calendar(0, true, Some("cal stale"))),
            "error",
        ),
    ];
    for (i, (mb, cal, expected)) in cases.into_iter().enumerate() {
        let h = harness().await;
        h.mailbox_tx.send(mb).unwrap();
        h.calendar_tx.send(cal).unwrap();
        let mut c = Client::connect(&h).await;
        let st = c.call("fred.get_state", json!({})).await;
        assert_eq!(st["state"], expected, "case {i}: {st}");
    }
}

#[tokio::test]
async fn fred_get_state_reports_counts_and_both_channels() {
    let h = harness().await;
    h.mailbox_tx.send(Some(mailbox(4, false, None, false))).unwrap();
    h.calendar_tx.send(Some(calendar(2, false, None))).unwrap();
    let mut c = Client::connect(&h).await;
    let st = c.call("fred.get_state", json!({})).await;
    assert_eq!(st["state"], "fresh", "{st}");
    assert_eq!(st["unread_count"], 4, "{st}");
    assert_eq!(st["today_event_count"], 2, "{st}");
    assert_eq!(st["mailbox"].as_array().map(Vec::len), Some(4), "{st}");
    assert_eq!(st["calendar"].as_array().map(Vec::len), Some(2), "{st}");
    assert_eq!(st["mailbox_state"], "fresh", "{st}");
    assert_eq!(st["calendar_state"], "fresh", "{st}");
    assert!(st["updated_at"].is_string(), "{st}");
}

#[tokio::test]
async fn fred_list_calendar_events_wraps_events_with_state_and_filters_by_date() {
    let h = harness().await;
    h.calendar_tx.send(Some(calendar(2, false, None))).unwrap();
    let mut c = Client::connect(&h).await;

    let all = c.call("fred.list_calendar_events", json!({})).await;
    assert_eq!(all["state"], "fresh", "{all}");
    assert_eq!(all["events"].as_array().map(Vec::len), Some(2), "{all}");

    let other_day = c
        .call("fred.list_calendar_events", json!({ "date": "2026-10-10" }))
        .await;
    assert_eq!(other_day["events"].as_array().map(Vec::len), Some(0), "{other_day}");

    let bad = c
        .call("fred.list_calendar_events", json!({ "date": "not-a-date" }))
        .await;
    assert_eq!(bad["error"], "bad_date", "{bad}");
}

#[tokio::test]
async fn fred_calendar_failure_is_an_error_with_a_reason() {
    let h = harness().await;
    h.calendar_tx
        .send(Some(calendar(0, false, Some("cal down"))))
        .unwrap();
    let mut c = Client::connect(&h).await;
    let res = c.call("fred.list_calendar_events", json!({})).await;
    assert_eq!(res["state"], "error", "{res}");
    assert_eq!(res["reason"], "cal down", "{res}");
}

// ═════════════════════════════════════════════════════════════════════════════
// Secrets never leak through any tool output
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn no_tool_output_ever_contains_a_planted_graph_token() {
    const SENTINEL: &str = "SENTINEL-TOKEN-do-not-leak-7f3a9c";
    let h = harness().await;
    // A token cache sitting where an auth flow would keep it.
    let cache = h.dir.path().join("graph-token.json");
    std::fs::write(
        &cache,
        json!({"access_token": SENTINEL, "refresh_token": SENTINEL, "expires_at": 0})
            .to_string(),
    )
    .unwrap();

    // Exercise the auth path, the error path and the healthy path.
    h.mailbox_tx.send(Some(mailbox(1, false, None, true))).unwrap();
    h.calendar_tx
        .send(Some(calendar(1, false, Some("cal down"))))
        .unwrap();
    h.todos_tx.send(Some(todos(1, false, None))).unwrap();
    h.jobs_tx.send(vec![job("j1", "running")]).unwrap();

    let mut c = Client::connect(&h).await;
    let mut all = String::new();
    for (name, args) in [
        ("teri.list_todos", json!({})),
        ("fred.get_state", json!({})),
        ("fred.list_unread_emails", json!({})),
        ("fred.list_calendar_events", json!({})),
        ("nostromo.list_views", json!({})),
        ("mother.get_status", json!({})),
        ("mother.list_jobs", json!({})),
    ] {
        all.push_str(&c.call(name, args).await.to_string());
    }
    assert!(!all.is_empty());
    assert!(
        !all.contains(SENTINEL),
        "a tool output leaked token material: {all}"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// nostromo.list_views / mother.get_status
// ═════════════════════════════════════════════════════════════════════════════

fn view<'a>(views: &'a Value, name: &str) -> &'a Value {
    views
        .as_array()
        .unwrap_or_else(|| panic!("list_views must return an array: {views}"))
        .iter()
        .find(|v| v["name"] == name)
        .unwrap_or_else(|| panic!("no view named {name:?} in {views}"))
}

#[tokio::test]
async fn list_views_in_the_daemon_reports_live_counts_for_every_channel() {
    let h = harness().await;
    h.todos_tx.send(Some(todos(3, false, None))).unwrap();
    h.mailbox_tx.send(Some(mailbox(5, false, None, false))).unwrap();
    h.calendar_tx.send(Some(calendar(2, false, None))).unwrap();
    h.queue_tx
        .send(Some(
            serde_json::from_value(json!({
                "generated_at": null, "stale": false, "error": null,
                "items": [
                    {"repo":"a/b","number":1,"title":"t","author":"x","url":"u"},
                    {"repo":"a/b","number":2,"title":"t","author":"x","url":"u"}
                ]
            }))
            .unwrap(),
        ))
        .unwrap();
    h.jobs_tx
        .send(vec![
            job("r1", "running"),
            job("r2", "running"),
            job("q1", "queued"),
            job("a1", "awaiting"),
            job("f1", "failed"),
            job("d1", "done"),
        ])
        .unwrap();

    let mut c = Client::connect(&h).await;
    let views = c.call("nostromo.list_views", json!({})).await;

    assert_eq!(view(&views, "teri")["counts"]["active_todos"], 3, "{views}");
    assert_eq!(view(&views, "fred")["counts"]["unread"], 5, "{views}");
    assert_eq!(view(&views, "fred")["counts"]["today_events"], 2, "{views}");
    assert_eq!(view(&views, "perri")["counts"]["queue"], 2, "{views}");
    let m = &view(&views, "mother")["counts"];
    assert_eq!(m["running"], 2, "{views}");
    assert_eq!(m["queued"], 1, "{views}");
    assert_eq!(m["awaiting"], 1, "{views}");
    assert_eq!(m["failed"], 1, "{views}");

    for name in ["teri", "fred", "perri", "mother"] {
        assert!(view(&views, name)["state"].is_string(), "{name} needs a state: {views}");
    }
}

#[tokio::test]
async fn list_views_state_is_loading_until_a_source_publishes() {
    let h = harness().await;
    let mut c = Client::connect(&h).await;
    let views = c.call("nostromo.list_views", json!({})).await;
    assert_eq!(view(&views, "teri")["state"], "loading", "{views}");
    assert_eq!(view(&views, "fred")["state"], "loading", "{views}");
    assert_eq!(view(&views, "perri")["state"], "loading", "{views}");

    h.todos_tx.send(Some(todos(1, false, None))).unwrap();
    let views = c.call("nostromo.list_views", json!({})).await;
    assert_eq!(view(&views, "teri")["state"], "fresh", "{views}");
}

#[tokio::test]
async fn mother_get_status_in_the_daemon_is_derived_from_the_job_list() {
    let h = harness().await;
    h.jobs_tx
        .send(vec![
            job("r1", "running"),
            job("q1", "queued"),
            job("q2", "ready"),
            job("a1", "awaiting"),
            job("f1", "failed"),
            job("f2", "failed"),
            job("f3", "failed"),
        ])
        .unwrap();
    let mut c = Client::connect(&h).await;
    let st = c.call("mother.get_status", json!({})).await;
    assert!(!st.is_null(), "daemon get_status must not be null");
    assert_eq!(st["running"], 1, "{st}");
    assert_eq!(st["queued"], 2, "{st}");
    assert_eq!(st["awaiting"], 1, "{st}");
    assert_eq!(st["failed"], 3, "{st}");
}

#[tokio::test]
async fn mother_get_status_with_no_jobs_is_all_zero_not_null() {
    let h = harness().await;
    let mut c = Client::connect(&h).await;
    let st = c.call("mother.get_status", json!({})).await;
    assert_eq!(st["running"], 0, "{st}");
    assert_eq!(st["failed"], 0, "{st}");
}

// ═════════════════════════════════════════════════════════════════════════════
// Mother mutators -> `mother` CLI via MOTHER_BIN
// ═════════════════════════════════════════════════════════════════════════════

/// `MOTHER_BIN` is process-global; serialize every test that sets it.
static ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// A fake `mother` executable plus its argv log. Holds the env lock and
/// restores `MOTHER_BIN` on drop.
struct FakeMother {
    dir: TempDir,
    prev: Option<std::ffi::OsString>,
    _guard: tokio::sync::MutexGuard<'static, ()>,
}

impl FakeMother {
    async fn install() -> FakeMother {
        let guard = ENV_LOCK.lock().await;
        let dir = TempDir::new().unwrap();
        let script = dir.path().join("mother");
        let body = r#"#!/bin/sh
here="$(dirname "$0")"
echo "$@" >> "$here/argv.log"
if [ -e "$here/fail" ]; then
  echo "boom: bad plan" >&2
  exit 1
fi
case "$1" in
  add) echo "abc123" ;;
  list) echo "[]" ;;
esac
exit 0
"#;
        std::fs::write(&script, body).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let prev = std::env::var_os("MOTHER_BIN");
        std::env::set_var("MOTHER_BIN", &script);
        FakeMother {
            dir,
            prev,
            _guard: guard,
        }
    }

    fn make_fail(&self) {
        std::fs::write(self.dir.path().join("fail"), "").unwrap();
    }

    /// Every invocation's argv, one joined line each.
    fn calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.path().join("argv.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The first invocation whose subcommand is `sub`.
    fn call_of(&self, sub: &str) -> String {
        self.calls()
            .into_iter()
            .find(|l| l.split_whitespace().next() == Some(sub))
            .unwrap_or_else(|| panic!("fake mother never saw `{sub}`; saw {:?}", self.calls()))
    }
}

impl Drop for FakeMother {
    fn drop(&mut self) {
        match &self.prev {
            Some(v) => std::env::set_var("MOTHER_BIN", v),
            None => std::env::remove_var("MOTHER_BIN"),
        }
    }
}

fn plan_file(dir: &Path) -> PathBuf {
    let p = dir.join("plan.md");
    std::fs::write(&p, "# plan\n").unwrap();
    p
}

#[tokio::test]
async fn enqueue_job_runs_mother_add_and_returns_the_new_job_id() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let plan = plan_file(h.dir.path());
    let mut c = Client::connect(&h).await;

    let res = c
        .call(
            "mother.enqueue_job",
            json!({
                "plan_path": plan,
                "repo": "acme/web",
                "branch": "feat/x",
                "repo_path": "/tmp/acme-web",
                "base": "develop",
                "max_cost": 7,
                "label": "my-label",
                "depends_on": ["a", "b"],
            }),
        )
        .await;

    assert!(res.get("error").is_none(), "{res}");
    assert!(res.to_string().contains("abc123"), "result must carry the job id: {res}");

    let argv = fake.call_of("add");
    let prefix = format!(
        "add --plan-file {} --repo acme/web --branch feat/x",
        plan.display()
    );
    assert!(argv.starts_with(&prefix), "argv was: {argv}");
    assert!(argv.ends_with("--format text"), "argv was: {argv}");
    assert!(argv.contains("--depends-on a,b"), "argv was: {argv}");
    for v in ["/tmp/acme-web", "develop", "7", "my-label"] {
        assert!(argv.contains(v), "optional arg {v:?} missing from: {argv}");
    }
}

#[tokio::test]
async fn enqueue_job_with_only_the_required_args_omits_the_optional_flags() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let plan = plan_file(h.dir.path());
    let mut c = Client::connect(&h).await;

    let res = c
        .call(
            "mother.enqueue_job",
            json!({ "plan_path": plan, "repo": "acme/web", "branch": "feat/x" }),
        )
        .await;
    assert!(res.to_string().contains("abc123"), "{res}");
    assert!(!fake.call_of("add").contains("--depends-on"));
}

#[tokio::test]
async fn enqueue_job_without_repo_or_branch_is_invalid_args_and_never_runs_mother() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let plan = plan_file(h.dir.path());
    let mut c = Client::connect(&h).await;

    let missing_repo = c
        .call("mother.enqueue_job", json!({ "plan_path": plan, "branch": "b" }))
        .await;
    assert_eq!(missing_repo["error"], "invalid_args", "{missing_repo}");
    assert!(
        missing_repo["detail"].as_str().unwrap_or("").contains("required"),
        "{missing_repo}"
    );

    let missing_branch = c
        .call("mother.enqueue_job", json!({ "plan_path": plan, "repo": "r" }))
        .await;
    assert_eq!(missing_branch["error"], "invalid_args", "{missing_branch}");
    assert!(
        missing_branch["detail"].as_str().unwrap_or("").contains("required"),
        "{missing_branch}"
    );

    assert!(fake.calls().is_empty(), "no CLI call for invalid args");
}

#[tokio::test]
async fn enqueue_job_surfaces_the_cli_s_stderr_when_mother_fails() {
    let fake = FakeMother::install().await;
    fake.make_fail();
    let h = harness().await;
    let plan = plan_file(h.dir.path());
    let mut c = Client::connect(&h).await;

    let res = c
        .call(
            "mother.enqueue_job",
            json!({ "plan_path": plan, "repo": "acme/web", "branch": "feat/x" }),
        )
        .await;
    let err = res
        .get("error")
        .unwrap_or_else(|| panic!("a failing CLI must produce an error: {res}"))
        .to_string();
    assert!(err.contains("boom: bad plan"), "{res}");
    assert!(!err.contains("event_loop_closed"), "{res}");
}

#[tokio::test]
async fn cancel_job_runs_mother_cancel_and_rebroadcasts_the_job_list() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let mut bcast = h.broadcast_tx.subscribe();
    let mut c = Client::connect(&h).await;

    let res = c.call("mother.cancel_job", json!({ "id": "job-9" })).await;
    assert_eq!(res["ok"], true, "{res}");
    assert!(fake.call_of("cancel").contains("job-9"));

    let got = tokio::time::timeout(BOUND, async {
        loop {
            match bcast.recv().await {
                Ok(ServerMsg::MotherJobs { .. }) => return true,
                Ok(_) => continue,
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => return false,
            }
        }
    })
    .await
    .expect("a MotherJobs broadcast must follow a cancel");
    assert!(got);
}

#[tokio::test]
async fn archive_retry_and_resume_invoke_the_cli_and_report_ok() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    let res = c.call("mother.archive_job", json!({ "id": "j1" })).await;
    assert_eq!(res["ok"], true, "{res}");
    assert!(fake.call_of("archive").contains("j1"));

    let res = c.call("mother.retry_job", json!({ "id": "j2" })).await;
    assert_eq!(res["ok"], true, "{res}");
    assert!(fake.call_of("retry").contains("j2"));

    let res = c
        .call("mother.resume_job", json!({ "id": "j3", "answer": "yes go" }))
        .await;
    assert_eq!(res["ok"], true, "{res}");
    assert_eq!(fake.call_of("resume"), "resume -- j3 yes go");
}

#[tokio::test]
async fn job_mutators_surface_the_cli_s_stderr_on_failure() {
    let fake = FakeMother::install().await;
    fake.make_fail();
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    for (tool, args) in [
        ("mother.cancel_job", json!({ "id": "j1" })),
        ("mother.archive_job", json!({ "id": "j1" })),
        ("mother.retry_job", json!({ "id": "j1" })),
        ("mother.resume_job", json!({ "id": "j1", "answer": "x" })),
    ] {
        let res = c.call(tool, args).await;
        let err = res
            .get("error")
            .unwrap_or_else(|| panic!("{tool} must error when the CLI fails: {res}"))
            .to_string();
        assert!(err.contains("boom: bad plan"), "{tool}: {res}");
        assert!(!err.contains("event_loop_closed"), "{tool}: {res}");
    }
}

#[tokio::test]
async fn job_mutators_with_missing_args_are_invalid_args() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    let res = c.call("mother.cancel_job", json!({})).await;
    assert_eq!(res["error"], "invalid_args", "{res}");
    let res = c.call("mother.resume_job", json!({ "id": "j1" })).await;
    assert_eq!(res["error"], "invalid_args", "{res}");
    assert!(fake.calls().is_empty());
}

// Silence "never read" on fields kept alive only for their Drop behaviour.
#[allow(dead_code)]
fn _keep(h: &Harness) {
    let _ = &h.server;
}
