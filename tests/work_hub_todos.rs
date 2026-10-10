//! Teri todos through the work hub: how a todos snapshot becomes a source
//! status plus work items, what the hub broadcasts (and when), and the real
//! thing end to end (a SQLite file changed by another connection reaches the
//! broadcast within 5 s).
//!
//! Behavioural only: nothing here looks at how the hub is wired inside.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use chrono::{NaiveDate, Utc};
use nostromo::data::teri_todos::{TeriTodo, TeriTodosNativeSource, TeriTodosSnapshot};
use nostromo::data::work::hub::{HubDeps, WorkHub};
use nostromo::data::work::query::WorkFilter;
use nostromo::data::work::todos::adapt;
use nostromo::data::work::{SourceState, SourceStatus, WorkItem, WorkService, WorkSource};
use nostromo::ipc::protocol::ServerMsg;
use rusqlite::Connection;
use tokio::sync::{broadcast, watch};

const WAIT: Duration = Duration::from_secs(5);

// ── builders ──────────────────────────────────────────────────────────────────

fn todo(
    id: i64,
    title: &str,
    status: &str,
    priority: u8,
    due: Option<&str>,
    jira: Option<&str>,
    body: Option<&str>,
) -> TeriTodo {
    TeriTodo {
        id,
        title: title.into(),
        status: status.into(),
        priority,
        due_date: due.map(Into::into),
        jira_key: jira.map(Into::into),
        body: body.map(Into::into),
    }
}

fn fresh(items: Vec<TeriTodo>) -> TeriTodosSnapshot {
    TeriTodosSnapshot { generated_at: Some(Utc::now()), items, ..Default::default() }
}

fn ids(items: &[WorkItem]) -> Vec<String> {
    items.iter().map(|i| i.id.clone()).collect()
}

fn titles(items: &[WorkItem]) -> Vec<String> {
    items.iter().map(|i| i.title.clone()).collect()
}

/// Spawn a hub fed by a channel we control (no database involved).
fn hub_with_channel(
    initial: Option<TeriTodosSnapshot>,
) -> (std::sync::Arc<WorkHub>, watch::Sender<Option<TeriTodosSnapshot>>, broadcast::Receiver<ServerMsg>)
{
    let (btx, brx) = broadcast::channel(1024);
    let (ttx, trx) = watch::channel(initial);
    let hub = WorkHub::spawn(HubDeps::new(btx, trx));
    (hub, ttx, brx)
}

/// Next frame for which `pick` returns `Some`, within `WAIT`.
async fn recv_until<T>(
    rx: &mut broadcast::Receiver<ServerMsg>,
    mut pick: impl FnMut(&ServerMsg) -> Option<T>,
) -> T {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(left, rx.recv()).await {
            Err(_) => panic!("timed out after {WAIT:?} waiting for the expected broadcast frame"),
            Ok(Ok(msg)) => {
                if let Some(v) = pick(&msg) {
                    return v;
                }
            }
            Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
            Ok(Err(broadcast::error::RecvError::Closed)) => panic!("broadcast channel closed"),
        }
    }
}

fn todos_snapshot(msg: &ServerMsg) -> Option<Vec<WorkItem>> {
    match msg {
        ServerMsg::WorkSnapshot { source: WorkSource::Todos, items, .. } => Some(items.clone()),
        _ => None,
    }
}

/// Wait for the next Todos snapshot whose item titles satisfy `pred`.
async fn next_todos_where(
    rx: &mut broadcast::Receiver<ServerMsg>,
    pred: impl Fn(&[WorkItem]) -> bool,
) -> Vec<WorkItem> {
    recv_until(rx, |m| todos_snapshot(m).filter(|items| pred(items))).await
}

async fn wait_for_status(
    hub: &WorkHub,
    source: WorkSource,
    pred: impl Fn(&SourceStatus) -> bool,
) -> SourceStatus {
    let deadline = Instant::now() + WAIT;
    loop {
        let s = hub.status(source);
        if pred(&s) {
            return s;
        }
        assert!(Instant::now() < deadline, "status of {source:?} never matched; last: {s:?}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

// ── the todos → status/items mapping ──────────────────────────────────────────

#[test]
fn a_user_without_a_teri_database_is_not_configured_with_a_plain_english_reason() {
    let snap = TeriTodosSnapshot { not_configured: true, generated_at: Some(Utc::now()), ..Default::default() };
    let (status, items) = adapt(&snap);

    assert_eq!(status.source, WorkSource::Todos);
    assert_eq!(status.state, SourceState::NotConfigured);
    assert!(items.is_empty());
    assert_eq!(status.count, 0);
    let reason = status.reason.expect("not_configured must say why");
    assert!(reason.contains("teri.db"), "reason should name the missing store: {reason}");
}

#[test]
fn a_failed_read_that_kept_the_last_items_is_stale_and_still_shows_them() {
    let snap = TeriTodosSnapshot {
        generated_at: Some(Utc::now()),
        items: vec![todo(1, "Keep me", "open", 2, None, None, None)],
        stale: true,
        error: Some("database is locked".into()),
        ..Default::default()
    };
    let (status, items) = adapt(&snap);

    assert_eq!(status.state, SourceState::Stale);
    assert_eq!(ids(&items), vec!["todo:1"]);
    assert_eq!(status.count, 1);
    assert!(status.reason.as_deref().is_some_and(|r| !r.is_empty()), "stale needs a reason");
}

#[test]
fn a_failed_read_with_nothing_to_show_is_an_error_with_a_reason_never_empty() {
    let snap = TeriTodosSnapshot {
        generated_at: Some(Utc::now()),
        error: Some("no such table: todos".into()),
        stale: false,
        ..Default::default()
    };
    let (status, items) = adapt(&snap);

    assert_eq!(status.state, SourceState::Error);
    assert!(items.is_empty());
    assert!(status.reason.as_deref().is_some_and(|r| !r.is_empty()), "error needs a reason");
}

#[test]
fn a_healthy_read_with_no_active_todos_is_empty() {
    let (status, items) = adapt(&fresh(vec![]));
    assert_eq!(status.state, SourceState::Empty);
    assert_eq!(status.count, 0);
    assert!(items.is_empty());
}

#[test]
fn a_healthy_read_with_todos_is_fresh_with_a_count_and_a_timestamp() {
    let snap = fresh(vec![
        todo(1, "One", "open", 3, None, None, None),
        todo(2, "Two", "blocked", 1, None, None, None),
    ]);
    let (status, items) = adapt(&snap);

    assert_eq!(status.state, SourceState::Fresh);
    assert_eq!(status.count, 2);
    assert_eq!(items.len(), 2);
    assert_eq!(status.updated_at, snap.generated_at, "updated_at is the last successful fetch");
}

#[test]
fn a_todo_becomes_a_work_item_with_priority_due_link_and_searchable_text() {
    let snap = fresh(vec![todo(
        7,
        "Fix payment webhook",
        "in_progress",
        2,
        Some("2026-10-15"),
        Some("CORE-1"),
        Some("Check the retry backoff in the worker."),
    )]);
    let (_, items) = adapt(&snap);
    let item = &items[0];

    assert_eq!(item.id, "todo:7");
    assert_eq!(item.source, WorkSource::Todos);
    assert_eq!(item.kind, "todo");
    assert_eq!(item.title, "Fix payment webhook");
    assert_eq!(item.status.as_deref(), Some("in_progress"));
    let p = item.priority.as_ref().expect("priority present");
    assert_eq!((p.label.as_str(), p.rank), ("P2", 2));
    assert_eq!(item.due, NaiveDate::from_ymd_opt(2026, 10, 15));
    assert_eq!(item.linked, vec!["CORE-1"]);
    assert!(item.search_text.contains("Fix payment webhook"), "title is searchable");
    assert!(item.search_text.contains("retry backoff"), "body is searchable");
}

#[test]
fn a_todo_with_no_body_and_an_unparseable_due_date_still_becomes_an_item() {
    let snap = fresh(vec![todo(3, "Odd one", "open", 5, Some("next tuesday"), None, None)]);
    let (_, items) = adapt(&snap);

    assert_eq!(items.len(), 1);
    assert_eq!(items[0].due, None, "a due date that is not a date is dropped, not fatal");
    assert!(items[0].search_text.contains("Odd one"));
    assert_eq!(items[0].priority.as_ref().map(|p| p.label.as_str()), Some("P5"));
}

// ── hub: ordering, statuses, broadcasts (channel-fed) ─────────────────────────

fn mixed_todos() -> Vec<TeriTodo> {
    vec![
        todo(1, "Write the quarterly report", "open", 3, Some("2026-10-12"), None, None),
        todo(2, "Book travel", "open", 1, None, None, None),
        todo(3, "Fix payment webhook", "in_progress", 1, Some("2026-10-11"), Some("CORE-1"), Some("Check the retry backoff.")),
        todo(4, "Audit access list", "blocked", 1, None, None, None),
        todo(5, "Order supplies", "open", 2, Some("2026-10-15"), None, None),
        todo(6, "Call the plumber", "open", 3, Some("2026-10-09"), None, None),
    ]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn todos_are_ordered_by_priority_then_due_date_none_last_then_title() {
    let (hub, _ttx, mut brx) = hub_with_channel(Some(fresh(mixed_todos())));

    let broadcast_items = next_todos_where(&mut brx, |i| i.len() == 6).await;
    let want = vec!["todo:3", "todo:4", "todo:2", "todo:5", "todo:6", "todo:1"];
    assert_eq!(ids(&broadcast_items), want, "broadcast order");
    assert_eq!(ids(&hub.items(&WorkFilter::default())), want, "hub.items order");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hub_status_for_todos_is_loading_until_the_source_reports() {
    let (hub, ttx, _brx) = hub_with_channel(None);
    assert_eq!(hub.status(WorkSource::Todos).state, SourceState::Loading);
    assert!(hub.items(&WorkFilter::default()).is_empty());

    ttx.send(Some(fresh(mixed_todos()))).unwrap();
    let s = wait_for_status(&hub, WorkSource::Todos, |s| s.state == SourceState::Fresh).await;
    assert_eq!(s.count, 6);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sources_without_an_implementation_yet_say_coming_soon() {
    let (hub, _ttx, _brx) = hub_with_channel(Some(fresh(vec![])));
    for source in [WorkSource::RepoDocs, WorkSource::Jira, WorkSource::Sentry] {
        let s = wait_for_status(&hub, source, |s| s.state == SourceState::NotConfigured).await;
        assert_eq!(s.reason.as_deref(), Some("Coming soon"), "{source:?}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_hub_reports_a_status_for_every_source() {
    let (hub, _ttx, _brx) = hub_with_channel(Some(fresh(mixed_todos())));
    wait_for_status(&hub, WorkSource::Todos, |s| s.state == SourceState::Fresh).await;

    let all = hub.statuses();
    let mut sources: Vec<WorkSource> = all.iter().map(|s| s.source).collect();
    sources.sort();
    assert_eq!(
        sources,
        vec![WorkSource::Todos, WorkSource::RepoDocs, WorkSource::Jira, WorkSource::Sentry]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_hub_broadcasts_the_todos_status_and_snapshot() {
    let (_hub, _ttx, mut brx) = hub_with_channel(Some(fresh(mixed_todos())));

    let status = recv_until(&mut brx, |m| match m {
        ServerMsg::WorkSourceStatus { status }
            if status.source == WorkSource::Todos && status.state == SourceState::Fresh =>
        {
            Some(status.clone())
        }
        _ => None,
    })
    .await;
    assert_eq!(status.count, 6);

    let group = recv_until(&mut brx, |m| match m {
        ServerMsg::WorkSnapshot { source: WorkSource::Todos, group, .. } => Some(group.clone()),
        _ => None,
    })
    .await;
    assert_eq!(group, None, "todos are a single ungrouped snapshot");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_missing_teri_store_broadcasts_not_configured_and_never_an_item_list() {
    let snap = TeriTodosSnapshot { not_configured: true, generated_at: Some(Utc::now()), ..Default::default() };
    let (hub, _ttx, mut brx) = hub_with_channel(Some(snap));

    wait_for_status(&hub, WorkSource::Todos, |s| s.state == SourceState::NotConfigured).await;
    let status = recv_until(&mut brx, |m| match m {
        ServerMsg::WorkSourceStatus { status } if status.source == WorkSource::Todos => Some(status.clone()),
        _ => None,
    })
    .await;
    assert_eq!(status.state, SourceState::NotConfigured);

    // Give the hub a moment to (wrongly) publish items, then check it never did.
    tokio::time::sleep(Duration::from_millis(400)).await;
    while let Ok(msg) = brx.try_recv() {
        if let Some(items) = todos_snapshot(&msg) {
            assert!(items.is_empty(), "no todos may be published for an unconfigured store");
        }
    }
    assert!(hub.items(&WorkFilter::default()).is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unchanged_snapshot_is_not_broadcast_again() {
    let first = fresh(mixed_todos());
    let (_hub, ttx, mut brx) = hub_with_channel(Some(first.clone()));
    let original = next_todos_where(&mut brx, |i| i.len() == 6).await;

    // The very same snapshot again, and again with only a newer timestamp
    // (what every poll of an unchanged database looks like)...
    ttx.send(Some(first.clone())).unwrap();
    ttx.send(Some(TeriTodosSnapshot { generated_at: Some(Utc::now()), ..first.clone() })).unwrap();
    // ...then a real change.
    let mut changed = mixed_todos();
    changed.push(todo(9, "Brand new todo", "open", 4, None, None, None));
    ttx.send(Some(fresh(changed))).unwrap();

    let next = recv_until(&mut brx, todos_snapshot).await;
    assert_ne!(
        ids(&next),
        ids(&original),
        "the next snapshot frame after an unchanged one must be the real change"
    );
    assert!(titles(&next).contains(&"Brand new todo".to_string()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_of_changes_is_coalesced_into_a_few_snapshots_ending_on_the_latest_state() {
    let (_hub, ttx, mut brx) = hub_with_channel(Some(fresh(vec![todo(1, "Seed", "open", 3, None, None, None)])));
    next_todos_where(&mut brx, |i| i.len() == 1).await;

    let started = Instant::now();
    let changes = 8;
    for n in 0..changes {
        let items = vec![todo(1, "Seed", "open", 3, None, None, None), todo(100 + n, &format!("Burst {n}"), "open", 4, None, None, None)];
        ttx.send(Some(fresh(items))).unwrap();
        tokio::task::yield_now().await;
    }
    let burst_took = started.elapsed();

    let last_title = format!("Burst {}", changes - 1);
    let mut received = 0usize;
    loop {
        let items = recv_until(&mut brx, todos_snapshot).await;
        received += 1;
        if titles(&items).contains(&last_title) {
            break;
        }
    }
    if burst_took > Duration::from_millis(100) {
        eprintln!("burst took {burst_took:?}; machine too loaded to assert on coalescing");
        return;
    }
    assert!(received <= 4, "{changes} rapid changes produced {received} snapshots; they should be coalesced");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hub_items_apply_a_filter_to_todos() {
    let (hub, _ttx, mut brx) = hub_with_channel(Some(fresh(mixed_todos())));
    next_todos_where(&mut brx, |i| i.len() == 6).await;

    let by_body = hub.items(&WorkFilter { query: "backoff".into(), ..Default::default() });
    assert_eq!(ids(&by_body), vec!["todo:3"]);

    let blocked = hub.items(&WorkFilter { statuses: vec!["blocked".into()], ..Default::default() });
    assert_eq!(ids(&blocked), vec!["todo:4"]);

    let jira_only = hub.items(&WorkFilter { sources: vec![WorkSource::Jira], ..Default::default() });
    assert!(jira_only.is_empty(), "no Jira items exist yet");
}

// ── hub: item detail ──────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_todos_detail_has_its_body_priority_due_status_and_jira_link() {
    let (hub, _ttx, mut brx) = hub_with_channel(Some(fresh(mixed_todos())));
    next_todos_where(&mut brx, |i| i.len() == 6).await;

    let d = hub.detail("todo:3").await.expect("detail for a known todo");

    assert_eq!(d.item_id, "todo:3");
    assert_eq!(d.title, "Fix payment webhook");
    assert!(d.markdown.contains("Check the retry backoff."), "body is the markdown: {:?}", d.markdown);
    let values: Vec<&str> = d.fields.iter().map(|(_, v)| v.as_str()).collect();
    assert!(values.contains(&"P1"), "priority field: {:?}", d.fields);
    assert!(values.iter().any(|v| v.contains("2026-10-11")), "due field: {:?}", d.fields);
    assert!(values.iter().any(|v| v.contains("in_progress") || v.contains("In progress") || v.contains("in progress")), "status field: {:?}", d.fields);
    let mentions_jira = values.iter().any(|v| v.contains("CORE-1"))
        || d.links.iter().any(|l| l.url.contains("CORE-1") || l.label.contains("CORE-1"))
        || d.markdown.contains("CORE-1");
    assert!(mentions_jira, "the linked Jira key must be in the detail: {d:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_detail_request_for_an_unknown_item_is_an_error() {
    let (hub, _ttx, mut brx) = hub_with_channel(Some(fresh(mixed_todos())));
    next_todos_where(&mut brx, |i| i.len() == 6).await;

    assert!(hub.detail("bogus:1").await.is_err(), "unknown prefix");
    assert!(hub.detail("todo:9999").await.is_err(), "a todo that does not exist");
}

// ── the real source: SQLite file → broadcast ─────────────────────────────────

fn open_wal(path: &Path) -> Connection {
    let conn = Connection::open(path).unwrap();
    let mode: String = conn.query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0)).unwrap();
    assert_eq!(mode.to_lowercase(), "wal");
    conn
}

/// The `todos` table exactly as Teri's `migrations/001_init.sql` creates it.
const TODOS_DDL: &str = "
CREATE TABLE IF NOT EXISTS todos (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  title           TEXT NOT NULL,
  body            TEXT,
  status          TEXT NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open','in_progress','done','cancelled','blocked')),
  priority        INTEGER NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  due_date        TEXT,
  jira_key        TEXT,
  parent_id       INTEGER REFERENCES todos(id),
  recurrence      TEXT,
  source          TEXT NOT NULL DEFAULT 'user'
                    CHECK (source IN ('user','sub_agent','briefing','import','jira')),
  source_ref      TEXT,
  idempotency_key TEXT UNIQUE,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL,
  completed_at    TEXT,
  snoozed_until   TEXT
);";

fn insert(
    conn: &Connection,
    title: &str,
    status: &str,
    priority: i64,
    due: Option<&str>,
    jira: Option<&str>,
    snoozed_until: Option<&str>,
) -> i64 {
    let now = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    conn.execute(
        "INSERT INTO todos (title, body, status, priority, due_date, jira_key, created_at, updated_at, snoozed_until)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?8)",
        rusqlite::params![title, format!("Body of {title}"), status, priority, due, jira, now, snoozed_until],
    )
    .unwrap();
    conn.last_insert_rowid()
}

struct Db {
    _dir: tempfile::TempDir,
    path: PathBuf,
    writer: Connection,
}

/// Teri's database with two active todos, one done and one snoozed into the future.
fn seeded_db() -> Db {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("teri.db");
    let writer = open_wal(&path);
    writer.execute_batch(TODOS_DDL).unwrap();
    insert(&writer, "Prepare demo", "open", 2, Some("2026-10-20"), None, None);
    insert(&writer, "Fix flaky test", "blocked", 1, None, Some("ABC-1"), None);
    insert(&writer, "Already finished", "done", 1, None, None, None);
    let tomorrow = (Utc::now() + chrono::Duration::days(1)).format("%Y-%m-%d %H:%M:%S").to_string();
    insert(&writer, "Snoozed until tomorrow", "open", 1, None, None, Some(&tomorrow));
    Db { _dir: dir, path, writer }
}

fn hub_on_db(path: PathBuf) -> (std::sync::Arc<WorkHub>, broadcast::Receiver<ServerMsg>) {
    let (btx, brx) = broadcast::channel(1024); // subscribed before anything can send
    let todos_rx = TeriTodosNativeSource::spawn_at(path);
    let hub = WorkHub::spawn(HubDeps::new(btx, todos_rx));
    (hub, brx)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_active_unsnoozed_todos_are_broadcast_with_p1_first() {
    let db = seeded_db();
    let (_hub, mut brx) = hub_on_db(db.path.clone());

    let items = next_todos_where(&mut brx, |i| !i.is_empty()).await;

    assert_eq!(titles(&items), vec!["Fix flaky test", "Prepare demo"]);
    assert_eq!(items[0].priority.as_ref().map(|p| p.label.as_str()), Some("P1"));
    assert_eq!(items[0].linked, vec!["ABC-1"]);
    assert_eq!(items[1].due, NaiveDate::from_ymd_opt(2026, 10, 20));
    assert!(items[1].search_text.contains("Body of Prepare demo"), "body reaches search_text");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn adding_completing_and_reprioritising_a_todo_reach_the_hub_within_five_seconds_each() {
    let db = seeded_db();
    let (hub, mut brx) = hub_on_db(db.path.clone());
    next_todos_where(&mut brx, |i| i.len() == 2).await;

    // Add (another connection, as Teri's own tooling would).
    let new_id = insert(&db.writer, "Email vendor", "open", 3, None, None, None);
    let after_add = next_todos_where(&mut brx, |i| titles(i).contains(&"Email vendor".to_string())).await;
    assert_eq!(titles(&after_add), vec!["Fix flaky test", "Prepare demo", "Email vendor"]);

    // Complete.
    db.writer
        .execute("UPDATE todos SET status = 'done', completed_at = datetime('now') WHERE title = 'Fix flaky test'", [])
        .unwrap();
    let after_done = next_todos_where(&mut brx, |i| !titles(i).contains(&"Fix flaky test".to_string())).await;
    assert_eq!(titles(&after_done), vec!["Prepare demo", "Email vendor"]);

    // Reprioritise.
    db.writer.execute("UPDATE todos SET priority = 1 WHERE id = ?1", [new_id]).unwrap();
    let after_prio = next_todos_where(&mut brx, |i| {
        i.first().is_some_and(|f| f.title == "Email vendor")
    })
    .await;
    assert_eq!(titles(&after_prio), vec!["Email vendor", "Prepare demo"]);
    assert_eq!(after_prio[0].priority.as_ref().map(|p| p.rank), Some(1));

    // The hub's own view agrees with what it broadcast.
    assert_eq!(titles(&hub.items(&WorkFilter::default())), vec!["Email vendor", "Prepare demo"]);
    assert_eq!(hub.status(WorkSource::Todos).state, SourceState::Fresh);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_missing_database_is_not_configured_and_never_published_as_an_empty_list() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join(".teri").join("teri.db");
    let (hub, mut brx) = hub_on_db(missing);

    let status = wait_for_status(&hub, WorkSource::Todos, |s| s.state == SourceState::NotConfigured).await;
    let reason = status.reason.expect("a reason");
    assert!(reason.contains("teri.db"), "{reason}");
    assert!(
        !reason.contains(dir.path().to_string_lossy().as_ref()),
        "the reason must not leak the real filesystem path: {reason}"
    );

    tokio::time::sleep(Duration::from_millis(400)).await;
    while let Ok(msg) = brx.try_recv() {
        if let Some(items) = todos_snapshot(&msg) {
            assert!(items.is_empty(), "no items for a store that does not exist");
        }
        if let ServerMsg::WorkSourceStatus { status } = &msg {
            if status.source == WorkSource::Todos {
                assert_eq!(status.state, SourceState::NotConfigured, "never fresh/empty: {status:?}");
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_corrupt_database_is_a_visible_failure_not_an_empty_or_fresh_list() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("teri.db");
    std::fs::write(&path, vec![0xAB_u8; 4096]).unwrap();
    let (hub, _brx) = hub_on_db(path);

    let status = wait_for_status(&hub, WorkSource::Todos, |s| {
        !matches!(s.state, SourceState::Loading)
    })
    .await;

    assert!(
        matches!(status.state, SourceState::Stale | SourceState::Error),
        "a broken store must surface as stale/error, got {:?}",
        status.state
    );
    assert!(status.reason.as_deref().is_some_and(|r| !r.is_empty()));
}
