//! MCP `list_work_items` / `get_work_item`: the agent-facing view of the same
//! work items the hub broadcasts to the Mac app.

use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use nostromo::data::teri_todos::{TeriTodo, TeriTodosSnapshot};
use nostromo::data::work::hub::{HubDeps, WorkHub};
use nostromo::data::work::query::WorkFilter;
use nostromo::data::work::{WorkItem, WorkSource};
use nostromo::ipc::protocol::ServerMsg;
use nostromo::mcp::tools::teri::{get_work_item, list_work_items};
use nostromo::mcp::McpSharedState;
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, watch};

const WAIT: Duration = Duration::from_secs(5);

fn todo(id: i64, title: &str, status: &str, priority: u8, due: Option<&str>, body: Option<&str>) -> TeriTodo {
    TeriTodo {
        id,
        title: title.into(),
        status: status.into(),
        priority,
        due_date: due.map(Into::into),
        jira_key: None,
        body: body.map(Into::into),
    }
}

fn five_todos() -> Vec<TeriTodo> {
    vec![
        todo(1, "Write the quarterly report", "open", 3, Some("2026-10-12"), Some("Collect the numbers from finance first.")),
        todo(2, "Fix payment webhook", "in_progress", 1, Some("2026-10-11"), Some("Check the retry backoff in the worker.")),
        todo(3, "Book travel", "open", 1, None, None),
        todo(4, "Audit access list", "blocked", 1, None, None),
        todo(5, "Order supplies", "open", 2, Some("2026-10-15"), None),
    ]
}

struct Rig {
    state: McpSharedState,
    hub: Arc<WorkHub>,
    brx: broadcast::Receiver<ServerMsg>,
    _ttx: watch::Sender<Option<TeriTodosSnapshot>>,
}

/// An MCP state whose hub has already published `todos`.
async fn rig(todos: Vec<TeriTodo>) -> Rig {
    let n = todos.len();
    let (btx, brx) = broadcast::channel(1024);
    // A separate receiver does the waiting, so `brx` still holds every frame for the test to inspect.
    let mut waiter = btx.subscribe();
    let (ttx, trx) = watch::channel(Some(TeriTodosSnapshot {
        generated_at: Some(Utc::now()),
        items: todos,
        ..Default::default()
    }));
    let hub = WorkHub::spawn(HubDeps::new(btx, trx));
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let mut state = McpSharedState::for_test(event_tx);
    state.work_hub = Some(hub.clone());

    // Wait until the hub has published (and so can answer for) every todo.
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(left, waiter.recv()).await.expect("hub never published todos") {
            Ok(ServerMsg::WorkSnapshot { source: WorkSource::Todos, items, .. }) if items.len() == n => break,
            _ => continue,
        }
    }
    Rig { state, hub, brx, _ttx: ttx }
}

fn ids_of(result: &Value) -> Vec<String> {
    result["items"]
        .as_array()
        .expect("items is an array")
        .iter()
        .map(|i| i["id"].as_str().expect("item id").to_string())
        .collect()
}

/// Ids of the most recent Todos snapshot the hub broadcast so far.
fn last_broadcast_todo_ids(brx: &mut broadcast::Receiver<ServerMsg>) -> Vec<String> {
    let mut last: Option<Vec<WorkItem>> = None;
    while let Ok(msg) = brx.try_recv() {
        if let ServerMsg::WorkSnapshot { source: WorkSource::Todos, items, .. } = msg {
            last = Some(items);
        }
    }
    last.expect("the hub broadcast a todos snapshot").iter().map(|i| i.id.clone()).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn list_work_items_for_todos_matches_the_broadcast_snapshot_ids_and_order() {
    let mut rig = rig(five_todos()).await;
    let broadcast_ids = last_broadcast_todo_ids(&mut rig.brx);

    let result = list_work_items(&rig.state, &json!({"source": "todos"}));

    assert_eq!(ids_of(&result), broadcast_ids);
    assert_eq!(ids_of(&result), vec!["todo:2", "todo:4", "todo:3", "todo:5", "todo:1"]);
    assert_eq!(result["total"], 5);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn list_work_items_reports_every_sources_status_and_never_leaks_search_text() {
    let rig = rig(five_todos()).await;

    let result = list_work_items(&rig.state, &json!({}));

    let statuses = result["statuses"].as_array().expect("statuses array");
    let todos = statuses.iter().find(|s| s["source"] == "todos").expect("a todos status");
    assert_eq!(todos["state"], "fresh");
    assert_eq!(todos["count"], 5);
    for source in ["repo_docs", "jira", "sentry"] {
        assert!(statuses.iter().any(|s| s["source"] == source), "no status for {source}");
    }
    for item in result["items"].as_array().unwrap() {
        assert!(item.get("search_text").is_none(), "search_text must not be sent to agents: {item}");
    }
    assert!(!result["items"].as_array().unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn limit_and_offset_page_through_the_items_and_total_ignores_them() {
    let rig = rig(five_todos()).await;
    let all = ids_of(&list_work_items(&rig.state, &json!({"source": "todos"})));

    let page1 = list_work_items(&rig.state, &json!({"source": "todos", "limit": 2}));
    assert_eq!(ids_of(&page1), all[0..2].to_vec());
    assert_eq!(page1["total"], 5, "total is the filtered count before paging");

    let page2 = list_work_items(&rig.state, &json!({"source": "todos", "limit": 2, "offset": 2}));
    assert_eq!(ids_of(&page2), all[2..4].to_vec());
    assert_eq!(page2["total"], 5);

    let past_end = list_work_items(&rig.state, &json!({"source": "todos", "offset": 50}));
    assert!(ids_of(&past_end).is_empty());
    assert_eq!(past_end["total"], 5);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn without_a_limit_at_most_one_hundred_items_are_returned() {
    let many: Vec<TeriTodo> = (1..=105)
        .map(|n| todo(n, &format!("Todo number {n:03}"), "open", 3, None, None))
        .collect();
    let rig = rig(many).await;

    let result = list_work_items(&rig.state, &json!({"source": "todos"}));

    assert_eq!(ids_of(&result).len(), 100);
    assert_eq!(result["total"], 105);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn query_filters_by_title_and_by_body_text() {
    let rig = rig(five_todos()).await;

    let by_title = list_work_items(&rig.state, &json!({"source": "todos", "query": "travel"}));
    assert_eq!(ids_of(&by_title), vec!["todo:3"]);
    assert_eq!(by_title["total"], 1);

    let by_body = list_work_items(&rig.state, &json!({"source": "todos", "query": "retry backoff"}));
    assert_eq!(ids_of(&by_body), vec!["todo:2"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn status_and_kind_arguments_filter_too() {
    let rig = rig(five_todos()).await;

    let blocked = list_work_items(&rig.state, &json!({"source": "todos", "status": "blocked"}));
    assert_eq!(ids_of(&blocked), vec!["todo:4"]);

    let wrong_kind = list_work_items(&rig.state, &json!({"source": "todos", "kind": "bug"}));
    assert!(ids_of(&wrong_kind).is_empty());
    assert_eq!(wrong_kind["total"], 0);

    let none_from_jira = list_work_items(&rig.state, &json!({"source": "jira"}));
    assert!(ids_of(&none_from_jira).is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_tool_agrees_with_the_hub() {
    let rig = rig(five_todos()).await;
    let from_hub: Vec<String> = rig.hub.items(&WorkFilter::default()).iter().map(|i| i.id.clone()).collect();

    let result = list_work_items(&rig.state, &json!({}));

    assert_eq!(ids_of(&result), from_hub);
}

#[tokio::test]
async fn without_a_hub_list_work_items_does_not_panic_and_returns_no_items() {
    let (event_tx, _rx) = mpsc::unbounded_channel();
    let state = McpSharedState::for_test(event_tx);
    assert!(state.work_hub.is_none());

    let result = list_work_items(&state, &json!({}));

    assert_eq!(result["items"], json!([]));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_work_item_returns_the_detail_for_a_todo() {
    let rig = rig(five_todos()).await;

    let d = get_work_item(&rig.state, &json!({"id": "todo:2"})).await;

    assert!(d.get("error").is_none(), "{d}");
    assert_eq!(d["item_id"], "todo:2");
    assert_eq!(d["title"], "Fix payment webhook");
    assert!(d["markdown"].as_str().unwrap().contains("Check the retry backoff in the worker."), "{d}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_work_item_reports_an_error_for_unknown_or_missing_ids() {
    let rig = rig(five_todos()).await;

    let unknown = get_work_item(&rig.state, &json!({"id": "bogus:1"})).await;
    assert!(unknown.get("error").is_some(), "{unknown}");

    let missing_arg = get_work_item(&rig.state, &json!({})).await;
    assert!(missing_arg.get("error").is_some(), "{missing_arg}");
}

#[tokio::test]
async fn without_a_hub_get_work_item_reports_an_error() {
    let (event_tx, _rx) = mpsc::unbounded_channel();
    let state = McpSharedState::for_test(event_tx);

    let d = get_work_item(&state, &json!({"id": "todo:1"})).await;

    assert!(d.get("error").is_some(), "{d}");
}
