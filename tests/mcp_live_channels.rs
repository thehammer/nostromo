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
use nostromo::mother::{JobsFeed, MotherJob, MotherSourceState};
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
    feed: JobsFeed,
    mailbox_tx: watch::Sender<Option<MailboxSnapshot>>,
    calendar_tx: watch::Sender<Option<CalendarSnapshot>>,
    todos_tx: watch::Sender<Option<TeriTodosSnapshot>>,
}

/// A daemon whose every source starts as "nothing published yet".
async fn harness() -> Harness {
    harness_with_feed(JobsFeed::new()).await
}

/// Like [`harness`], but the daemon is handed `feed` (a clone of it, exactly as
/// `nostromd` hands its poller's feed to the MCP server).
async fn harness_with_feed(feed: JobsFeed) -> Harness {
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
            mother: feed.clone(),
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
        feed,
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
        "not_configured": false,
    }))
    .unwrap()
}

/// What the Teri source publishes for a user who never set Teri up (no
/// `~/.teri/teri.db`): an empty state, not a failure.
fn todos_not_configured() -> TeriTodosSnapshot {
    serde_json::from_value(json!({
        "generated_at": "2026-10-09T15:00:00Z",
        "items": [],
        "stale": false,
        "error": null,
        "not_configured": true,
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
        "generated_at": "2026-10-09T15:00:00Z",
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

#[tokio::test]
async fn teri_list_todos_for_a_user_without_a_teri_database_is_not_configured_with_a_path_free_reason() {
    let h = harness().await;
    h.todos_tx.send(Some(todos_not_configured())).unwrap();
    let mut c = Client::connect(&h).await;

    let res = c.call("teri.list_todos", json!({})).await;
    assert_eq!(res["state"], "not_configured", "{res}");
    assert_eq!(res["items"].as_array().map(Vec::len), Some(0), "{res}");
    assert_eq!(res["reason"], "Teri has no database yet", "{res}");
    let reason = res["reason"].as_str().unwrap();
    assert!(!reason.contains('/'), "reason must not leak a path: {reason}");
    if let Ok(home) = std::env::var("HOME") {
        assert!(!res.to_string().contains(&home), "no $HOME in output: {res}");
    }

    let views = c.call("nostromo.list_views", json!({})).await;
    assert_eq!(view(&views, "teri")["state"], "not_configured", "{views}");
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

#[tokio::test]
async fn fred_list_calendar_events_carries_the_snapshots_timestamp() {
    let h = harness().await;
    h.calendar_tx.send(Some(calendar(1, false, None))).unwrap();
    let mut c = Client::connect(&h).await;
    let res = c.call("fred.list_calendar_events", json!({})).await;
    assert_eq!(res["updated_at"], "2026-10-09T15:00:00Z", "{res}");
}

#[tokio::test]
async fn fred_get_state_has_an_updated_at_even_when_the_calendar_is_the_worst_source() {
    let h = harness().await;
    // Mailbox is fresh with a *different* timestamp, so an `updated_at` that
    // came from the mailbox can't masquerade as the calendar's.
    let mut mb = mailbox(1, false, None, false);
    mb.generated_at = Some("2026-10-09T14:00:00Z".parse().unwrap());
    h.mailbox_tx.send(Some(mb)).unwrap();
    h.calendar_tx
        .send(Some(calendar(1, false, Some("cal down"))))
        .unwrap();
    let mut c = Client::connect(&h).await;
    let st = c.call("fred.get_state", json!({})).await;
    assert_eq!(st["state"], "error", "{st}");
    assert_eq!(st["reason"], "cal down", "{st}");
    assert_eq!(st["updated_at"], "2026-10-09T15:00:00Z", "{st}");
}

// ═════════════════════════════════════════════════════════════════════════════
// Secrets never leak through any tool output
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn sign_in_prompt_exposes_only_the_device_code_fields_and_no_tool_output_carries_token_material() {
    let h = harness().await;
    h.mailbox_tx.send(Some(mailbox(1, false, None, true))).unwrap();
    h.calendar_tx
        .send(Some(calendar(1, false, Some("cal down"))))
        .unwrap();
    h.todos_tx.send(Some(todos(1, false, None))).unwrap();
    h.feed.publish_jobs(vec![job("j1", "running")]);

    let mut c = Client::connect(&h).await;

    let keys = |v: &Value| -> Vec<String> {
        let mut k: Vec<String> = v
            .as_object()
            .unwrap_or_else(|| panic!("auth must be an object: {v}"))
            .keys()
            .cloned()
            .collect();
        k.sort();
        k
    };
    let want = ["expires_at", "user_code", "verification_uri"];
    let st = c.call("fred.get_state", json!({})).await;
    assert_eq!(keys(&st["auth"]), want, "{st}");
    let unread = c.call("fred.list_unread_emails", json!({})).await;
    assert_eq!(keys(&unread["auth"]), want, "{unread}");

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
    for needle in ["access_token", "refresh_token"] {
        assert!(!all.contains(needle), "a tool output mentions {needle}: {all}");
    }
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
    h.feed.publish_jobs(vec![
            job("r1", "running"),
            job("r2", "running"),
            job("q1", "queued"),
            job("a1", "awaiting"),
            job("f1", "failed"),
            job("d1", "done"),
        ]);

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
    assert_eq!(view(&views, "mother")["state"], "loading", "{views}");

    h.todos_tx.send(Some(todos(1, false, None))).unwrap();
    h.feed.publish_jobs(vec![]);
    let views = c.call("nostromo.list_views", json!({})).await;
    assert_eq!(view(&views, "teri")["state"], "fresh", "{views}");
    assert_eq!(view(&views, "mother")["state"], "fresh", "{views}");
}

#[tokio::test]
async fn list_views_mother_state_follows_the_job_feed_including_failures() {
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    h.feed.publish_failure("x");
    let views = c.call("nostromo.list_views", json!({})).await;
    assert_eq!(view(&views, "mother")["state"], "error", "{views}");

    h.feed.publish_jobs(vec![job("r1", "running")]);
    h.feed.publish_failure("later failure");
    let views = c.call("nostromo.list_views", json!({})).await;
    assert_eq!(view(&views, "mother")["state"], "stale", "{views}");
    assert_eq!(view(&views, "mother")["counts"]["running"], 1, "{views}");
}

#[tokio::test]
async fn mother_get_status_in_the_daemon_is_derived_from_the_job_list() {
    let h = harness().await;
    h.feed.publish_jobs(vec![
            job("r1", "running"),
            job("q1", "queued"),
            job("q2", "ready"),
            job("a1", "awaiting"),
            job("f1", "failed"),
            job("f2", "failed"),
            job("f3", "failed"),
        ]);
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

#[tokio::test]
async fn mother_get_status_says_loading_until_the_feed_publishes() {
    let h = harness().await;
    let mut c = Client::connect(&h).await;
    let st = c.call("mother.get_status", json!({})).await;
    assert_eq!(st["state"], "loading", "{st}");
    assert_eq!(st["running"], 0, "{st}");
    assert_eq!(st["queued"], 0, "{st}");
    assert_eq!(st["awaiting"], 0, "{st}");
    assert_eq!(st["failed"], 0, "{st}");
}

#[tokio::test]
async fn mother_get_status_is_fresh_after_a_publish_with_a_timestamp() {
    let h = harness().await;
    h.feed.publish_jobs(vec![job("r1", "running")]);
    let mut c = Client::connect(&h).await;
    let st = c.call("mother.get_status", json!({})).await;
    assert_eq!(st["state"], "fresh", "{st}");
    assert_eq!(st["running"], 1, "{st}");
    assert!(st["updated_at"].is_string(), "{st}");
}

#[tokio::test]
async fn mother_get_status_is_error_when_the_list_has_never_succeeded() {
    let h = harness().await;
    h.feed.publish_failure("x");
    let mut c = Client::connect(&h).await;
    let st = c.call("mother.get_status", json!({})).await;
    assert_eq!(st["state"], "error", "{st}");
    assert_eq!(st["reason"], "x", "{st}");
}

#[tokio::test]
async fn mother_get_status_is_stale_after_a_failure_following_a_success_and_keeps_the_jobs() {
    let h = harness().await;
    h.feed.publish_jobs(vec![job("r1", "running"), job("f1", "failed")]);
    h.feed.publish_failure("broker down");
    let mut c = Client::connect(&h).await;

    let st = c.call("mother.get_status", json!({})).await;
    assert_eq!(st["state"], "stale", "{st}");
    assert_eq!(st["reason"], "broker down", "{st}");
    assert!(st["updated_at"].is_string(), "{st}");
    assert_eq!(st["running"], 1, "{st}");
    assert_eq!(st["failed"], 1, "{st}");

    let jobs = c.call("mother.list_jobs", json!({})).await;
    assert_eq!(jobs.as_array().map(Vec::len), Some(2), "{jobs}");
}

// ═════════════════════════════════════════════════════════════════════════════
// nostromo.get_rate_limits / get_budget_posture in the daemon
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn daemon_rate_limits_and_budget_posture_say_not_available_with_a_reason_not_null() {
    let h = harness().await;
    let mut c = Client::connect(&h).await;
    for tool in ["nostromo.get_rate_limits", "nostromo.get_budget_posture"] {
        let res = c.call(tool, json!({})).await;
        assert_eq!(res["state"], "not_available", "{tool}: {res}");
        assert!(
            res["reason"].as_str().is_some_and(|r| !r.trim().is_empty()),
            "{tool} needs a non-empty reason: {res}"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Shared channel: the feed the daemon is handed is the poller's feed
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_feed_handle_cloned_before_the_server_is_built_publishes_into_the_same_channel() {
    // `nostromd` creates the feed, hands a clone to its poller, and hands the
    // feed to `DaemonSources`. A poller publish must be visible to the MCP
    // readers no matter which side was built first.
    let poller_handle = JobsFeed::new();
    let h = harness_with_feed(poller_handle.clone()).await;
    let mut c = Client::connect(&h).await;
    assert_eq!(c.call("mother.list_jobs", json!({})).await, json!([]));

    poller_handle.publish_jobs(vec![job("from-poller", "running")]);

    let jobs = c.call("mother.list_jobs", json!({})).await;
    assert_eq!(jobs[0]["id"], "from-poller", "{jobs}");
}

// ═════════════════════════════════════════════════════════════════════════════
// Mother mutators -> `mother` CLI via MOTHER_BIN
// ═════════════════════════════════════════════════════════════════════════════

/// `MOTHER_BIN` is process-global; serialize every test that sets it.
static ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// One `mother` subcommand's grammar. `usage` is the line `mother --help`
/// prints for it (verified against the real binary by
/// `grammar_usage_lines_match_the_installed_mother_help`); the rest is what the
/// fake needs to reject what the real CLI rejects.
struct Grammar {
    sub: &'static str,
    usage: &'static str,
    value_flags: &'static [&'static str],
    bool_flags: &'static [&'static str],
    required_flags: &'static [&'static str],
    /// Positional args allowed: (min, max). The first is the job id where
    /// there is one.
    positionals: (usize, usize),
    /// `resume` only: exactly one of ANSWER / `--from-file PATH` / `-`.
    answer_source: bool,
    /// What the real CLI says when handed a bare `--`.
    dashdash_err: &'static str,
}

const GRAMMAR: &[Grammar] = &[
    Grammar {
        sub: "add",
        usage: "mother add --plan-file PATH --repo NAME --branch BRANCH [options]",
        value_flags: &[
            "--plan-file", "--repo", "--branch", "--repo-path", "--base", "--max-cost",
            "--depends-on", "--title", "--format", "--label",
        ],
        bool_flags: &[],
        required_flags: &["--plan-file", "--repo", "--branch"],
        positionals: (0, 0),
        answer_source: false,
        dashdash_err: "add: unknown flag: --",
    },
    Grammar {
        sub: "list",
        usage: "mother list [--state STATE] [--repo REPO] [--project NAME] [--label LABEL] [--format json|table]",
        value_flags: &["--state", "--repo", "--project", "--label", "--format"],
        bool_flags: &[],
        required_flags: &[],
        positionals: (0, 0),
        answer_source: false,
        dashdash_err: "list: unknown flag: --",
    },
    Grammar {
        sub: "cancel",
        usage: "mother cancel ID",
        value_flags: &[],
        bool_flags: &[],
        required_flags: &[],
        positionals: (1, 1),
        answer_source: false,
        dashdash_err: "no such job: --",
    },
    Grammar {
        sub: "force-start",
        usage: "mother force-start ID [--yes] [--ignore-deps]",
        value_flags: &[],
        bool_flags: &["--yes", "--ignore-deps"],
        required_flags: &[],
        positionals: (1, 1),
        answer_source: false,
        dashdash_err: "force-start: <id> required",
    },
    Grammar {
        sub: "retry",
        usage: "mother retry ID [--yes]",
        value_flags: &[],
        bool_flags: &["--yes"],
        required_flags: &[],
        positionals: (1, 1),
        answer_source: false,
        dashdash_err: "retry: unknown flag: --",
    },
    Grammar {
        sub: "resume",
        usage: "mother resume ID ANSWER | --from-file PATH | -",
        value_flags: &["--from-file", "--max-cost"],
        bool_flags: &[],
        required_flags: &[],
        positionals: (1, 2),
        answer_source: true,
        dashdash_err: "resume: <id> required",
    },
    Grammar {
        // `mother --help` lists only the bulk form; the daemon archives one
        // job with `archive ID`, which the fake accepts as an optional ID.
        sub: "archive",
        usage: "mother archive [--older-than DAYS] [--dry-run]",
        value_flags: &["--older-than"],
        bool_flags: &["--dry-run"],
        required_flags: &[],
        positionals: (0, 1),
        answer_source: false,
        dashdash_err: "archive: unknown flag: --",
    },
];

/// The fake `mother`: validates argv against [`GRAMMAR`] (real-style error on
/// stderr + non-zero exit on a violation), logs every call, and supports the
/// failure modes the tests switch on with marker files in its directory.
fn fake_script() -> String {
    let words = |flags: &[&str]| format!("\" {} \"", flags.join(" "));
    let quoted = |s: &str| format!("\"{s}\"");
    let mut cases = String::new();
    for g in GRAMMAR {
        cases.push_str(&format!(
            "  {sub}) VFLAGS={v}; BFLAGS={b}; RFLAGS={r}; PMIN={min}; PMAX={max}; ANSWER={ans}; DDERR='{dd}' ;;\n",
            sub = g.sub,
            v = words(g.value_flags),
            b = words(g.bool_flags),
            r = quoted(&g.required_flags.join(" ")),
            min = g.positionals.0,
            max = g.positionals.1,
            ans = if g.answer_source { 1 } else { 0 },
            dd = g.dashdash_err,
        ));
    }
    FAKE_BODY.replace("@CASES@", &cases)
}

const FAKE_BODY: &str = r#"#!/bin/sh
here="$(dirname "$0")"
printf '%s\n' "$*" >> "$here/argv.log"
fail() { echo "$1" >&2; exit 2; }
sub="$1"
[ $# -gt 0 ] && shift
case "$sub" in
@CASES@  *) fail "mother: unknown command: $sub" ;;
esac

npos=0; id=""; seen=" "; fromfile=""; yes=""
while [ $# -gt 0 ]; do
  a="$1"
  case "$a" in
    --) fail "$DDERR" ;;
    -) npos=$((npos+1)); [ $npos -eq 1 ] && id="$a" ;;
    -*)
      case "$VFLAGS" in
        *" $a "*)
          [ $# -ge 2 ] || fail "$sub: flag needs an argument: $a"
          seen="$seen$a "
          [ "$a" = "--from-file" ] && fromfile="$2"
          shift ;;
        *)
          case "$BFLAGS" in
            *" $a "*) seen="$seen$a "; [ "$a" = "--yes" ] && yes=1 ;;
            *) fail "$sub: unknown flag: $a" ;;
          esac ;;
      esac ;;
    *) npos=$((npos+1)); [ $npos -eq 1 ] && id="$a" ;;
  esac
  shift
done
[ $npos -ge "$PMIN" ] || fail "$sub: <id> required"
[ $npos -le "$PMAX" ] || fail "$sub: unexpected argument"
for f in $RFLAGS; do
  case "$seen" in *" $f "*) ;; *) fail "$sub: $f is required" ;; esac
done
if [ "$ANSWER" = 1 ]; then
  n=$((npos-1)); [ -n "$fromfile" ] && n=$((n+1))
  [ $n -eq 1 ] || fail "resume: exactly one of ANSWER, --from-file PATH or - is required"
fi

if [ -e "$here/fail" ]; then
  echo "boom: bad plan" >&2
  exit 1
fi
if [ -e "$here/sleep_on" ] && [ "$(cat "$here/sleep_on")" = "$sub" ]; then
  echo $$ > "$here/pid.$sub"
  exec sleep 30
fi
# Real CLI: the open-PR guard is skipped by --yes (retry has no prompt at all).
if [ -e "$here/openpr" ] && { [ "$sub" = retry ] || [ "$sub" = force-start ]; } && [ -z "$yes" ]; then
  printf "mother: refusing - job %s's branch 'b' already has an open pull request: https://example.invalid/pr/1 ... use 'mother reconcile %s ...'\n" "$id" "$id" >&2
  exit 1
fi
if [ -e "$here/prompt" ] && [ "$sub" = force-start ] && [ -z "$yes" ]; then
  if read -r _ans; then
    echo "aborted: not confirmed" >&2
  else
    echo "aborted: confirmation required" >&2
  fi
  exit 1
fi
if [ -e "$here/list_fail" ] && [ "$sub" = list ]; then
  echo "[]"
  echo "mother: database is locked" >&2
  exit 1
fi

case "$sub" in
  add)
    echo "abc123"
    printf '[{"id":"abc123","state":"queued"}]' > "$here/list.json" ;;
  list)
    if [ -e "$here/list.json" ]; then cat "$here/list.json"; else echo "[]"; fi ;;
  cancel)
    if [ -e "$here/list.json" ]; then
      sed 's/"running"/"cancelled"/g' "$here/list.json" > "$here/list.tmp" && mv "$here/list.tmp" "$here/list.json"
    fi ;;
  archive)
    printf '[]' > "$here/list.json" ;;
  resume)
    if [ -n "$fromfile" ]; then
      cat "$fromfile" > "$here/answer.last" || fail "resume: cannot read $fromfile"
      printf '%s' "$fromfile" > "$here/answer_path.last"
    fi ;;
esac
exit 0
"#;

/// A fake `mother` executable plus its argv log. Holds the env lock and
/// restores `MOTHER_BIN` (and any env set through [`FakeMother::set_env`]) on
/// drop; kills any fake still sleeping.
struct FakeMother {
    dir: TempDir,
    saved_env: Vec<(&'static str, Option<std::ffi::OsString>)>,
    _guard: tokio::sync::MutexGuard<'static, ()>,
}

impl FakeMother {
    async fn install() -> FakeMother {
        let guard = ENV_LOCK.lock().await;
        let dir = TempDir::new().unwrap();
        let script = dir.path().join("mother");
        std::fs::write(&script, fake_script()).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let mut fake = FakeMother {
            dir,
            saved_env: Vec::new(),
            _guard: guard,
        };
        fake.set_env("MOTHER_BIN", script.as_os_str());
        fake
    }

    fn path(&self) -> PathBuf {
        self.dir.path().join("mother")
    }

    /// Set a process env var for the life of this fake (restored on drop).
    fn set_env(&mut self, key: &'static str, value: impl AsRef<std::ffi::OsStr>) {
        self.saved_env.push((key, std::env::var_os(key)));
        std::env::set_var(key, value);
    }

    /// Every call fails with `boom: bad plan` on stderr.
    fn make_fail(&self) {
        self.mode("fail");
    }

    /// Switch on a failure mode: `fail`, `openpr`, `prompt`, `list_fail`.
    fn mode(&self, name: &str) {
        std::fs::write(self.dir.path().join(name), "").unwrap();
    }

    /// Make `sub` write its pid and then sleep 30 s.
    fn sleep_on(&self, sub: &str) {
        std::fs::write(self.dir.path().join("sleep_on"), sub).unwrap();
    }

    fn sleeper_pid(&self, sub: &str) -> Option<u32> {
        std::fs::read_to_string(self.dir.path().join(format!("pid.{sub}")))
            .ok()
            .and_then(|s| s.trim().parse().ok())
    }

    /// What the fake's `list --format json` prints.
    fn write_list(&self, json: &str) {
        std::fs::write(self.dir.path().join("list.json"), json).unwrap();
    }

    /// Contents of the `--from-file` the last `resume` was handed, as copied
    /// at call time (the daemon deletes the file afterwards).
    fn last_answer(&self) -> String {
        std::fs::read_to_string(self.dir.path().join("answer.last"))
            .unwrap_or_else(|e| panic!("fake never copied a resume --from-file: {e}"))
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

    /// The most recent invocation whose subcommand is `sub`.
    fn last_call_of(&self, sub: &str) -> String {
        self.calls()
            .into_iter()
            .rev()
            .find(|l| l.split_whitespace().next() == Some(sub))
            .unwrap_or_else(|| panic!("fake mother never saw `{sub}`; saw {:?}", self.calls()))
    }
}

impl Drop for FakeMother {
    fn drop(&mut self) {
        for (key, prev) in self.saved_env.drain(..).rev() {
            match prev {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
        // Don't leave a sleeper behind when a test failed before it was reaped.
        for sub in ["add", "cancel", "retry", "list", "archive", "resume"] {
            if let Some(pid) = self.sleeper_pid(sub) {
                let _ = std::process::Command::new("kill").arg(pid.to_string()).output();
            }
        }
    }
}

fn pid_alive(pid: u32) -> bool {
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn plan_file(dir: &Path) -> PathBuf {
    let p = dir.join("plan.md");
    std::fs::write(&p, "# plan\n").unwrap();
    p
}

/// Run the fake directly; returns (exit success, stderr).
fn run_fake(fake: &FakeMother, args: &[&str]) -> (bool, String) {
    let out = std::process::Command::new(fake.path()).args(args).output().unwrap();
    (out.status.success(), String::from_utf8_lossy(&out.stderr).into_owned())
}

// ── the fake itself must enforce the real grammar (else the tests below are vacuous)

#[tokio::test]
async fn the_fake_mother_rejects_what_the_real_cli_rejects() {
    let fake = FakeMother::install().await;
    for (args, want) in [
        (vec!["cancel", "--", "x"], "no such job: --"),
        (vec!["retry", "--", "x"], "retry: unknown flag: --"),
        (vec!["resume", "--", "x", "ans"], "resume: <id> required"),
        (vec!["force-start", "--yes", "--", "x"], "force-start: <id> required"),
        (vec!["cancel"], "<id> required"),
        (vec!["retry", "--bogus", "x"], "unknown flag"),
        (vec!["resume", "j"], "exactly one of"),
        (vec!["resume", "j", "a", "b"], "unexpected argument"),
        (vec!["resume", "j", "-x"], "unknown flag"),
        (vec!["resume", "j", "ans", "--from-file", "/x"], "exactly one of"),
        (vec!["add", "--repo", "r", "--branch", "b"], "--plan-file is required"),
    ] {
        let (ok, stderr) = run_fake(&fake, &args);
        assert!(!ok, "{args:?} must be rejected");
        assert!(stderr.contains(want), "{args:?}: stderr {stderr:?} lacks {want:?}");
    }
    for args in [
        vec!["cancel", "j"],
        vec!["retry", "--yes", "j"],
        vec!["resume", "j", "ans"],
        vec!["resume", "j", "-"],
        vec!["archive", "j"],
        vec!["force-start", "--yes", "j"],
    ] {
        let (ok, stderr) = run_fake(&fake, &args);
        assert!(ok, "{args:?} must be accepted: {stderr}");
    }
}

#[test]
fn grammar_usage_lines_match_the_installed_mother_help() {
    let path = std::env::var_os("PATH").unwrap_or_default();
    // Deliberately NOT MOTHER_BIN: that is the fake while other tests run.
    let Some(real) = std::env::split_paths(&path)
        .map(|d| d.join("mother"))
        .find(|c| c.is_file())
    else {
        eprintln!("SKIPPED: mother not on PATH");
        return;
    };
    // `--help` is read-only.
    let out = std::process::Command::new(&real).arg("--help").output().unwrap();
    let help = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    for g in GRAMMAR {
        assert!(
            help.contains(g.usage),
            "`{}` is not in the real `mother --help` (the fake's grammar has drifted):\n{help}",
            g.usage
        );
    }
}

// ── enqueue ──────────────────────────────────────────────────────────────────

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
                "repo": "nostromo",
                "branch": "feat/x",
                "repo_path": "/tmp/nostromo-checkout",
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
        "add --plan-file {} --repo nostromo --branch feat/x",
        plan.display()
    );
    assert!(argv.starts_with(&prefix), "argv was: {argv}");
    assert!(argv.ends_with("--format text"), "argv was: {argv}");
    assert!(argv.contains("--depends-on a,b"), "argv was: {argv}");
    for v in ["/tmp/nostromo-checkout", "develop", "7", "my-label"] {
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
            json!({ "plan_path": plan, "repo": "nostromo", "branch": "feat/x" }),
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
async fn enqueue_job_rejects_option_looking_values_and_never_runs_mother() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let plan = plan_file(h.dir.path());
    let mut c = Client::connect(&h).await;

    let valid = json!({ "plan_path": plan, "repo": "nostromo", "branch": "feat/x" });
    let with = |k: &str, v: Value| {
        let mut a = valid.clone();
        a[k] = v;
        a
    };
    for (what, args) in [
        ("repo", with("repo", json!("--yes"))),
        ("repo -x", with("repo", json!("-x"))),
        ("branch", with("branch", json!("--yes"))),
        ("branch -x", with("branch", json!("-x"))),
        ("base", with("base", json!("--yes"))),
        ("label", with("label", json!("-x"))),
        ("repo_path", with("repo_path", json!("--yes"))),
        ("depends_on first", with("depends_on", json!(["--yes", "ok"]))),
        ("depends_on later", with("depends_on", json!(["ok", "-x"]))),
    ] {
        let res = c.call("mother.enqueue_job", args).await;
        assert_eq!(res["error"], "invalid_args", "{what}: {res}");
        assert!(
            res["detail"].as_str().is_some_and(|d| !d.is_empty()),
            "{what} needs a detail: {res}"
        );
    }
    assert!(fake.calls().is_empty(), "no CLI call for invalid args: {:?}", fake.calls());
}

#[tokio::test]
async fn enqueue_job_requires_an_absolute_plan_path_and_still_reports_a_missing_one() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    let rel = c
        .call(
            "mother.enqueue_job",
            json!({ "plan_path": "plans/plan.md", "repo": "nostromo", "branch": "b" }),
        )
        .await;
    assert_eq!(rel["error"], "invalid_args", "{rel}");
    assert!(rel["detail"].as_str().unwrap_or("").contains("absolute"), "{rel}");

    let missing = c
        .call(
            "mother.enqueue_job",
            json!({ "plan_path": "/nonexistent/dir/plan.md", "repo": "nostromo", "branch": "b" }),
        )
        .await;
    assert_eq!(missing["error"], "plan_not_found", "{missing}");

    assert!(fake.calls().is_empty(), "no CLI call for either: {:?}", fake.calls());
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
            json!({ "plan_path": plan, "repo": "nostromo", "branch": "feat/x" }),
        )
        .await;
    let err = res
        .get("error")
        .unwrap_or_else(|| panic!("a failing CLI must produce an error: {res}"))
        .to_string();
    assert!(err.contains("boom: bad plan"), "{res}");
    assert!(!err.contains("event_loop_closed"), "{res}");
}

// ── job mutators: argv fidelity ──────────────────────────────────────────────

#[tokio::test]
async fn cancel_job_runs_mother_cancel_and_rebroadcasts_the_job_list() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let mut bcast = h.broadcast_tx.subscribe();
    let mut c = Client::connect(&h).await;

    let res = c.call("mother.cancel_job", json!({ "id": "job-9" })).await;
    assert_eq!(res["ok"], true, "{res}");
    assert_eq!(fake.call_of("cancel"), "cancel job-9");

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
async fn cancel_retry_and_archive_use_the_real_cli_argv() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    for (tool, id) in [
        ("mother.cancel_job", "j"),
        ("mother.retry_job", "j"),
        ("mother.archive_job", "j"),
    ] {
        let res = c.call(tool, json!({ "id": id })).await;
        assert_eq!(res["ok"], true, "{tool}: {res}");
    }
    assert_eq!(fake.call_of("cancel"), "cancel j");
    // `retry` takes NO --yes: in the real CLI that flag only overrides the open-PR guard.
    assert_eq!(fake.call_of("retry"), "retry j");
    assert_eq!(fake.call_of("archive"), "archive j");
}

#[tokio::test]
async fn resume_job_hands_the_answer_to_the_cli_in_a_file_never_in_argv() {
    let fake = FakeMother::install().await;
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    for answer in [
        "yes go",
        "-x --yes",
        "first line\nsecond line\n\n  indented, with $HOME and `ticks` and 'quotes'\n",
    ] {
        let res = c
            .call("mother.resume_job", json!({ "id": "j3", "answer": answer }))
            .await;
        assert_eq!(res["ok"], true, "answer {answer:?}: {res}");

        let argv = fake.last_call_of("resume");
        let parts: Vec<&str> = argv.split_whitespace().collect();
        assert_eq!(parts.len(), 4, "argv was: {argv}");
        assert_eq!(&parts[..3], ["resume", "j3", "--from-file"], "argv was: {argv}");
        assert!(!argv.contains(answer), "the answer must not be in argv: {argv}");

        assert_eq!(fake.last_answer(), answer, "file contents must be the answer exactly");

        // The daemon cleans up the temp file once the CLI has returned.
        assert!(
            !Path::new(parts[3]).exists(),
            "temp answer file {} should be deleted",
            parts[3]
        );
    }
}

#[tokio::test]
async fn force_start_uses_the_real_cli_argv() {
    let fake = FakeMother::install().await;
    nostromo::mother::force_start("jid").await.expect("force_start should succeed");
    assert_eq!(fake.call_of("force-start"), "force-start --yes jid");
}

// ── freshness: a mutation is visible to readers immediately ──────────────────

#[tokio::test]
async fn cancel_job_is_visible_to_every_reader_immediately_without_waiting_for_a_poll() {
    let fake = FakeMother::install().await;
    fake.write_list(r#"[{"id":"job-9","state":"running"}]"#);
    let h = harness().await;
    h.feed.publish_jobs(vec![job("job-9", "running")]);
    let mut c = Client::connect(&h).await;

    let res = c.call("mother.cancel_job", json!({ "id": "job-9" })).await;
    assert_eq!(res["ok"], true, "{res}");

    // No sleep, no poller: the very next reads must already show it.
    let jobs = c.call("mother.list_jobs", json!({})).await;
    assert_eq!(jobs.as_array().map(Vec::len), Some(1), "{jobs}");
    assert_eq!(jobs[0]["state"], "cancelled", "{jobs}");

    let st = c.call("mother.get_status", json!({})).await;
    assert_eq!(st["running"], 0, "{st}");
    assert_eq!(st["state"], "fresh", "{st}");

    let views = c.call("nostromo.list_views", json!({})).await;
    assert_eq!(view(&views, "mother")["counts"]["running"], 0, "{views}");
}

#[tokio::test]
async fn archive_job_removes_the_job_from_the_list_immediately() {
    let fake = FakeMother::install().await;
    fake.write_list(r#"[{"id":"job-9","state":"succeeded"}]"#);
    let h = harness().await;
    h.feed.publish_jobs(vec![job("job-9", "succeeded")]);
    let mut c = Client::connect(&h).await;

    let res = c.call("mother.archive_job", json!({ "id": "job-9" })).await;
    assert_eq!(res["ok"], true, "{res}");

    let jobs = c.call("mother.list_jobs", json!({})).await;
    assert_eq!(jobs.as_array().map(Vec::len), Some(0), "{jobs}");
}

#[tokio::test]
async fn enqueue_job_makes_the_new_job_visible_immediately() {
    let _fake = FakeMother::install().await;
    let h = harness().await;
    let plan = plan_file(h.dir.path());
    let mut c = Client::connect(&h).await;

    let res = c
        .call(
            "mother.enqueue_job",
            json!({ "plan_path": plan, "repo": "nostromo", "branch": "feat/x" }),
        )
        .await;
    assert!(res.to_string().contains("abc123"), "{res}");

    let jobs = c.call("mother.list_jobs", json!({})).await;
    assert!(
        jobs.as_array().is_some_and(|a| a.iter().any(|j| j["id"] == "abc123")),
        "the new job must be listed right away: {jobs}"
    );
}

#[tokio::test]
async fn a_failed_re_list_after_a_successful_mutation_keeps_ok_but_marks_the_status_stale() {
    let fake = FakeMother::install().await;
    fake.write_list(r#"[{"id":"job-9","state":"running"}]"#);
    let h = harness().await;
    h.feed.publish_jobs(vec![job("job-9", "running")]);
    fake.mode("list_fail");
    let mut c = Client::connect(&h).await;

    let res = c.call("mother.cancel_job", json!({ "id": "job-9" })).await;
    assert_eq!(res["ok"], true, "the cancel itself succeeded: {res}");

    let st = c.call("mother.get_status", json!({})).await;
    assert_eq!(st["state"], "stale", "{st}");
    assert!(
        st["reason"].as_str().is_some_and(|r| !r.is_empty()),
        "stale needs a reason: {st}"
    );
}

// ── hardening: timeout, open PR, confirmation prompts ────────────────────────

/// Poll up to 2 s for `pid` to be gone.
async fn dies_within_two_seconds(pid: u32) -> bool {
    for _ in 0..20 {
        if !pid_alive(pid) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    !pid_alive(pid)
}

#[tokio::test]
async fn enqueue_job_times_out_a_hung_cli_and_kills_it() {
    let mut fake = FakeMother::install().await;
    fake.set_env("NOSTROMO_MOTHER_CLI_TIMEOUT_MS", "500");
    fake.sleep_on("add");
    let h = harness().await;
    let plan = plan_file(h.dir.path());
    let mut c = Client::connect(&h).await;

    let res = c
        .call(
            "mother.enqueue_job",
            json!({ "plan_path": plan, "repo": "nostromo", "branch": "feat/x" }),
        )
        .await;
    assert!(res.get("error").is_some(), "a hung CLI must be an error: {res}");
    assert!(res.to_string().contains("timed out"), "{res}");

    let pid = fake.sleeper_pid("add").expect("the fake add should have started");
    assert!(dies_within_two_seconds(pid).await, "the hung CLI (pid {pid}) must be killed");
}

#[tokio::test]
async fn a_job_mutator_times_out_a_hung_cli_and_kills_it() {
    let mut fake = FakeMother::install().await;
    fake.set_env("NOSTROMO_MOTHER_CLI_TIMEOUT_MS", "500");
    fake.sleep_on("cancel");
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    let res = c.call("mother.cancel_job", json!({ "id": "job-9" })).await;
    assert!(res.get("error").is_some(), "a hung CLI must be an error: {res}");
    assert!(res.to_string().contains("timed out"), "{res}");

    let pid = fake.sleeper_pid("cancel").expect("the fake cancel should have started");
    assert!(dies_within_two_seconds(pid).await, "the hung CLI (pid {pid}) must be killed");
}

#[tokio::test]
async fn retry_of_a_job_whose_branch_has_an_open_pr_is_a_distinct_error_with_a_reconcile_hint() {
    let fake = FakeMother::install().await;
    fake.mode("openpr");
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    let res = c.call("mother.retry_job", json!({ "id": "j1" })).await;
    assert_eq!(res["error"], "mother_job_has_open_pr", "{res}");
    assert!(
        res["detail"].as_str().unwrap_or("").contains("open pull request"),
        "detail must carry the CLI's stderr: {res}"
    );
    assert!(
        res["hint"].as_str().unwrap_or("").contains("reconcile"),
        "hint must point at reconcile: {res}"
    );
}

#[tokio::test]
async fn retry_does_not_pass_yes_so_the_open_pr_guard_stays_on() {
    let fake = FakeMother::install().await;
    // The real `retry` has no prompt; `--yes` would only disable the open-PR guard.
    // With a job whose branch has an open PR the call must be refused, not forced.
    fake.mode("openpr");
    let h = harness().await;
    let mut c = Client::connect(&h).await;

    let res = c.call("mother.retry_job", json!({ "id": "j1" })).await;
    assert_eq!(res["error"], "mother_job_has_open_pr", "{res}");
    assert_eq!(fake.call_of("retry"), "retry j1", "retry must not pass --yes");
}

#[tokio::test]
async fn force_start_never_waits_on_a_confirmation_prompt() {
    let fake = FakeMother::install().await;
    fake.mode("prompt");
    nostromo::mother::force_start("jid")
        .await
        .expect("force_start must pass --yes");
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

// ── `nostromo::mother` helpers against the fake ──────────────────────────────

#[tokio::test]
async fn list_jobs_is_an_error_when_the_cli_exits_non_zero_even_with_valid_json_on_stdout() {
    let fake = FakeMother::install().await;
    fake.mode("list_fail");
    let err = nostromo::mother::list_jobs()
        .await
        .expect_err("a non-zero `mother list` must not be treated as an empty/ok list");
    assert!(err.to_string().contains("database is locked"), "{err:#}");
}

#[tokio::test]
async fn feed_refresh_publishes_fresh_on_success_then_stale_on_failure() {
    let fake = FakeMother::install().await;
    fake.write_list(r#"[{"id":"a","state":"running"}]"#);
    let feed = JobsFeed::new();

    let jobs = feed.refresh().await.expect("refresh should succeed");
    assert_eq!(jobs.len(), 1);
    assert!(matches!(*feed.source_rx().borrow(), MotherSourceState::Fresh { .. }));
    assert_eq!(feed.jobs_rx().borrow().len(), 1);

    fake.mode("list_fail");
    feed.refresh().await.expect_err("refresh should fail");
    match &*feed.source_rx().borrow() {
        MotherSourceState::Stale { reason, .. } => {
            assert!(reason.contains("database is locked"), "{reason}")
        }
        other => panic!("expected Stale after a failure following a success, got {other:?}"),
    }
    assert_eq!(feed.jobs_rx().borrow().len(), 1, "old jobs stay readable");
}

#[tokio::test]
async fn feed_refresh_that_has_never_succeeded_is_an_error_state() {
    let fake = FakeMother::install().await;
    fake.mode("list_fail");
    let feed = JobsFeed::new();

    feed.refresh().await.expect_err("refresh should fail");
    match &*feed.source_rx().borrow() {
        MotherSourceState::Error { reason } => {
            assert!(reason.contains("database is locked"), "{reason}")
        }
        other => panic!("expected Error when nothing ever succeeded, got {other:?}"),
    }
}

// Silence "never read" on fields kept alive only for their Drop behaviour.
#[allow(dead_code)]
fn _keep(h: &Harness) {
    let _ = &h.server;
}
