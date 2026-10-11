//! Teri's picks: 3-7 agent-chosen next actions, each with a reason.
//!
//! The only way to publish is the MCP tool `teri.publish_picks`; the daemon
//! validates the entries against the hub's current items, fills in what the
//! agent must not be trusted with (source, title, time, unavailable sources),
//! stores the result, and broadcasts it as a retained `TeriPicks` frame. The hub
//! keeps each pick's `done_since` honest as sources change, and a generator runs
//! a hidden Teri session to produce a new set on request.
//!
//! Behavioural only: the hub is driven through its todos channel, sessions are
//! faked at the `PicksSessionHost` seam, and every wait is a poll or a
//! broadcast receive with a deadline (never an assertion on elapsed time).

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::Utc;
use nostromo::data::teri_todos::{TeriTodo, TeriTodosSnapshot};
use nostromo::data::work::hub::{HubDeps, WorkHub};
use nostromo::data::work::picks::{
    PickEntry, PicksGenerator, PicksSessionHost, PicksStore, PublishError, GENERATION_TIMEOUT,
    MAX_PICKS, MAX_REASON_CHARS, MIN_PICKS, PICKS_AGENT, PICKS_PROMPT, PICKS_TAG,
};
use nostromo::data::work::{PicksSnapshot, SourceState, WorkService, WorkSource};
use nostromo::ipc::protocol::ServerMsg;
use nostromo::mcp::tools::teri::{get_picks, publish_picks};
use nostromo::mcp::tools::{dispatch, tool_descriptors, ToolResult};
use nostromo::mcp::McpSharedState;
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, watch};

const WAIT: Duration = Duration::from_secs(5);

// ── rig ───────────────────────────────────────────────────────────────────────

/// The hub reads (and prunes) the process-wide sent ledger, which defaults to
/// `~/.nostromo/teri/sent.json`. Point it, and the teri dir, at a temp dir once
/// per test process so these tests never touch the real one.
fn isolate_sent_ledger() {
    static DIR: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    DIR.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("nostromo-{}-teri-{}", "work-picks", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp teri dir");
        std::env::set_var("NOSTROMO_TERI_DIR", &dir);
        nostromo::data::work::sent::install_ledger(std::sync::Arc::new(
            nostromo::data::work::sent::SentLedger::new(dir.join("sent.json")),
        ));
        dir
    });
}

fn todo(id: i64, title: &str) -> TeriTodo {
    TeriTodo {
        id,
        title: title.into(),
        status: "open".into(),
        priority: 3,
        due_date: None,
        jira_key: None,
        body: None,
    }
}

/// Nine todos, `todo:1` .. `todo:9`.
fn nine_todos() -> Vec<TeriTodo> {
    let titles = [
        "Write the quarterly report",
        "Fix payment webhook",
        "Book travel",
        "Audit access list",
        "Order supplies",
        "Reply to the auditors",
        "Renew the domain",
        "Plan the offsite",
        "Clean up staging",
    ];
    titles.iter().enumerate().map(|(i, t)| todo(i as i64 + 1, t)).collect()
}

fn todos_without(ids: &[i64]) -> Vec<TeriTodo> {
    nine_todos().into_iter().filter(|t| !ids.contains(&t.id)).collect()
}

fn fresh(items: Vec<TeriTodo>) -> TeriTodosSnapshot {
    TeriTodosSnapshot { generated_at: Some(Utc::now()), items, ..Default::default() }
}

struct Rig {
    hub: Arc<WorkHub>,
    /// Holds every frame since the rig finished starting up.
    brx: broadcast::Receiver<ServerMsg>,
    ttx: watch::Sender<Option<TeriTodosSnapshot>>,
    dir: tempfile::TempDir,
}

impl Rig {
    fn picks_path(&self) -> PathBuf {
        self.dir.path().join("picks.json")
    }
}

async fn rig() -> Rig {
    rig_with(|_| {}).await
}

/// A hub fed nine todos, persisting picks under a temp dir, with repo docs read
/// from an empty temp folder. `tweak` can set the picks_* deps.
async fn rig_with(tweak: impl FnOnce(&mut HubDeps)) -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let docs_root = dir.path().join("code");
    fs::create_dir_all(&docs_root).unwrap();
    let (btx, brx) = broadcast::channel(1024);
    let mut waiter = btx.subscribe();
    let (ttx, trx) = watch::channel(Some(fresh(nine_todos())));
    isolate_sent_ledger();
    let mut deps = HubDeps {
        repo_docs_root: Some(docs_root),
        picks_path: Some(dir.path().join("picks.json")),
        ..HubDeps::new(btx, trx)
    };
    tweak(&mut deps);
    let hub = WorkHub::spawn(deps);

    // The hub announces its (empty) picks once on start.
    recv_until(&mut waiter, picks_frame).await;
    // Repo docs scans in the background; wait until it has a verdict so every
    // source's state is settled before a test publishes.
    wait_until("repo docs to leave loading", || hub.status(WorkSource::RepoDocs).state != SourceState::Loading).await;

    let mut rig = Rig { hub, brx, ttx, dir };
    drain_picks(&mut rig.brx);
    rig
}

async fn wait_until(what: &str, mut ok: impl FnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !ok() {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
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

fn picks_frame(msg: &ServerMsg) -> Option<PicksSnapshot> {
    match msg {
        ServerMsg::TeriPicks { picks } => Some(picks.clone()),
        _ => None,
    }
}

/// Every `TeriPicks` frame already waiting on `rx` (without blocking).
fn drain_picks(rx: &mut broadcast::Receiver<ServerMsg>) -> Vec<PicksSnapshot> {
    let mut out = Vec::new();
    loop {
        match rx.try_recv() {
            Ok(msg) => out.extend(picks_frame(&msg)),
            Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
            Err(_) => break,
        }
    }
    out
}

fn entries(ids: &[&str]) -> Vec<PickEntry> {
    ids.iter()
        .map(|id| PickEntry { item_id: id.to_string(), reason: format!("Because {id} is the thing to do next") })
        .collect()
}

fn ids_of(snap: &PicksSnapshot) -> Vec<String> {
    snap.items.iter().map(|p| p.item_id.clone()).collect()
}

fn pick<'a>(snap: &'a PicksSnapshot, id: &str) -> &'a nostromo::data::work::Pick {
    snap.items.iter().find(|p| p.item_id == id).unwrap_or_else(|| panic!("no pick {id} in {snap:?}"))
}

/// What the hub itself says is unavailable: every source not fresh/empty/stale.
fn expected_unavailable(hub: &WorkHub) -> Vec<WorkSource> {
    hub.statuses()
        .into_iter()
        .filter(|s| !matches!(s.state, SourceState::Fresh | SourceState::Empty | SourceState::Stale))
        .map(|s| s.source)
        .collect()
}

fn read_persisted(path: &std::path::Path) -> PicksSnapshot {
    let raw = fs::read_to_string(path).expect("picks file exists");
    serde_json::from_str(&raw).expect("picks file is a PicksSnapshot")
}

// ── 1. publish validation ─────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_limits_are_three_to_seven_picks_with_reasons_up_to_240_characters() {
    assert_eq!((MIN_PICKS, MAX_PICKS, MAX_REASON_CHARS), (3, 7, 240));
    assert_eq!(GENERATION_TIMEOUT, Duration::from_secs(5 * 60));
    assert!(PICKS_PROMPT.contains("teri_publish_picks"), "the prompt must name the tool to publish with");
    assert_eq!((PICKS_TAG, PICKS_AGENT), ("teri-picks", "teri:teri"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn publishing_two_picks_is_rejected_and_eight_is_rejected() {
    let rig = rig().await;

    let two = rig.hub.publish_picks(&entries(&["todo:1", "todo:2"]));
    assert_eq!(two, Err(PublishError::WrongCount(2)));

    let eight: Vec<String> = (1..=8).map(|n| format!("todo:{n}")).collect();
    let eight: Vec<&str> = eight.iter().map(String::as_str).collect();
    let eight = rig.hub.publish_picks(&entries(&eight));
    assert_eq!(eight, Err(PublishError::WrongCount(8)));

    assert!(rig.hub.picks().snapshot().items.is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn publishing_exactly_three_or_exactly_seven_is_accepted() {
    let rig = rig().await;

    let three = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).expect("3 is accepted");
    assert_eq!(three.items.len(), 3);

    let seven: Vec<String> = (1..=7).map(|n| format!("todo:{n}")).collect();
    let seven: Vec<&str> = seven.iter().map(String::as_str).collect();
    let seven = rig.hub.publish_picks(&entries(&seven)).expect("7 is accepted");
    assert_eq!(seven.items.len(), 7);
    assert_eq!(ids_of(&seven), (1..=7).map(|n| format!("todo:{n}")).collect::<Vec<_>>(), "the agent's order is kept");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unknown_item_id_is_rejected_and_the_message_names_it() {
    let rig = rig().await;

    let err = rig.hub.publish_picks(&entries(&["todo:1", "todo:999", "todo:2"])).unwrap_err();

    assert_eq!(err, PublishError::UnknownIds(vec!["todo:999".into()]));
    assert!(err.to_string().contains("todo:999"), "{err}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_unknown_id_is_listed_in_the_error() {
    let rig = rig().await;

    let err = rig.hub.publish_picks(&entries(&["todo:1", "todo:998", "doc:nope:bugs/open/x.md", "jira:ZZZ-1"])).unwrap_err();

    let PublishError::UnknownIds(ids) = &err else { panic!("expected UnknownIds, got {err:?}") };
    let ids: BTreeSet<&str> = ids.iter().map(String::as_str).collect();
    assert_eq!(ids, BTreeSet::from(["todo:998", "doc:nope:bugs/open/x.md", "jira:ZZZ-1"]));
    let text = err.to_string();
    for id in ["todo:998", "doc:nope:bugs/open/x.md", "jira:ZZZ-1"] {
        assert!(text.contains(id), "{text} should name {id}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_same_item_picked_twice_is_rejected_and_named() {
    let rig = rig().await;

    let err = rig.hub.publish_picks(&entries(&["todo:1", "todo:1", "todo:2"])).unwrap_err();

    assert_eq!(err, PublishError::DuplicateIds(vec!["todo:1".into()]));
    assert!(err.to_string().contains("todo:1"), "{err}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reason_of_240_characters_is_accepted_and_241_is_rejected() {
    let rig = rig().await;
    let with_reason = |reason: String| {
        let mut e = entries(&["todo:1", "todo:2", "todo:3"]);
        e[1].reason = reason;
        e
    };

    let ok = rig.hub.publish_picks(&with_reason("x".repeat(240))).expect("240 characters fit");
    assert_eq!(pick(&ok, "todo:2").reason.chars().count(), 240);

    let err = rig.hub.publish_picks(&with_reason("x".repeat(241))).unwrap_err();
    assert_eq!(err, PublishError::BadReasons(vec!["todo:2".into()]));
    assert!(err.to_string().contains("todo:2"), "{err}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_reason_limit_counts_characters_not_bytes() {
    let rig = rig().await;
    let mut e = entries(&["todo:1", "todo:2", "todo:3"]);

    e[0].reason = "é".repeat(240); // 480 bytes
    assert!(rig.hub.publish_picks(&e).is_ok(), "240 two-byte characters are 240 characters");

    e[0].reason = "é".repeat(241);
    assert_eq!(rig.hub.publish_picks(&e), Err(PublishError::BadReasons(vec!["todo:1".into()])));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_empty_or_blank_reason_is_rejected() {
    let rig = rig().await;
    for bad in ["", "   ", "\n\t "] {
        let mut e = entries(&["todo:1", "todo:2", "todo:3"]);
        e[2].reason = bad.to_string();

        let err = rig.hub.publish_picks(&e).unwrap_err();

        assert_eq!(err, PublishError::BadReasons(vec!["todo:3".into()]), "reason {bad:?}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rejected_publish_leaves_the_previous_picks_untouched_and_broadcasts_nothing() {
    let mut rig = rig().await;
    let before = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    drain_picks(&mut rig.brx);

    assert!(rig.hub.publish_picks(&entries(&["todo:4", "todo:5"])).is_err());
    assert!(rig.hub.publish_picks(&entries(&["todo:4", "todo:5", "todo:404"])).is_err());

    assert_eq!(rig.hub.picks().snapshot(), before);
    assert!(drain_picks(&mut rig.brx).is_empty(), "a rejected publish must not announce anything");
    assert_eq!(read_persisted(&rig.picks_path()), before, "nor change the stored file");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_accepted_publish_fills_source_title_and_time_from_the_daemon_and_broadcasts() {
    let mut rig = rig().await;
    let before = Utc::now();

    let snap = rig.hub.publish_picks(&entries(&["todo:2", "todo:1", "todo:3"])).unwrap();

    let after = Utc::now();
    assert_eq!(ids_of(&snap), vec!["todo:2", "todo:1", "todo:3"]);
    let p = pick(&snap, "todo:2");
    assert_eq!(p.source, WorkSource::Todos);
    assert_eq!(p.title, "Fix payment webhook");
    assert_eq!(p.reason, "Because todo:2 is the thing to do next");
    assert!(!p.done_since);
    let at = snap.generated_at.expect("generated_at is set");
    assert!(before <= at && at <= after, "{at} not within [{before}, {after}]");
    assert!(!snap.generating);
    assert_eq!(snap.error, None);
    assert_eq!(rig.hub.picks().snapshot(), snap);

    let frame = recv_until(&mut rig.brx, picks_frame).await;
    assert_eq!(frame, snap, "the broadcast carries what was stored");
}

// ── 2. unavailable sources ────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn unavailable_sources_come_from_the_hubs_own_source_states() {
    let rig = rig().await;
    let expected = expected_unavailable(&rig.hub);
    // In tests Jira and Sentry are dormant, and todos are healthy.
    assert!(expected.contains(&WorkSource::Jira) && expected.contains(&WorkSource::Sentry), "{expected:?}");
    assert!(!expected.contains(&WorkSource::Todos));

    let snap = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();

    assert_eq!(snap.unavailable_sources, expected);
    let mut sorted = snap.unavailable_sources.clone();
    sorted.sort();
    assert_eq!(snap.unavailable_sources, sorted, "listed in source order");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stale_source_is_not_listed_as_unavailable() {
    let mut rig = rig().await;
    // A failed read after a good one: the hub keeps the last list and marks it stale.
    rig.ttx
        .send(Some(TeriTodosSnapshot {
            generated_at: Some(Utc::now()),
            items: Vec::new(),
            stale: false,
            error: Some("database is locked".into()),
            not_configured: false,
        }))
        .unwrap();
    recv_until(&mut rig.brx, |m| match m {
        ServerMsg::WorkSourceStatus { status }
            if status.source == WorkSource::Todos && status.state == SourceState::Stale =>
        {
            Some(())
        }
        _ => None,
    })
    .await;

    let snap = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();

    assert_eq!(rig.hub.status(WorkSource::Todos).state, SourceState::Stale);
    assert!(!snap.unavailable_sources.contains(&WorkSource::Todos), "{:?}", snap.unavailable_sources);
    assert_eq!(snap.unavailable_sources, expected_unavailable(&rig.hub));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_agent_cannot_supply_unavailable_sources() {
    let rig = rig().await;
    let state = mcp_state(&rig);

    let out = publish_picks(
        &state,
        &json!({
            "unavailable_sources": [],
            "picks": [
                {"item_id": "todo:1", "reason": "r1", "unavailable_sources": []},
                {"item_id": "todo:2", "reason": "r2"},
                {"item_id": "todo:3", "reason": "r3"},
            ]
        }),
    );

    assert_eq!(out["ok"], true, "{out}");
    let stored: Vec<WorkSource> =
        serde_json::from_value(out["picks"]["unavailable_sources"].clone()).expect("unavailable_sources list");
    assert_eq!(stored, expected_unavailable(&rig.hub));
}

// ── 3. done_since ─────────────────────────────────────────────────────────────

async fn rig_with_three_picks() -> Rig {
    let mut rig = rig().await;
    rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    drain_picks(&mut rig.brx);
    rig
}

async fn wait_for_done(rig: &mut Rig, id: &str) -> PicksSnapshot {
    let id = id.to_string();
    recv_until(&mut rig.brx, move |m| {
        picks_frame(m).filter(|s| s.items.iter().any(|p| p.item_id == id && p.done_since))
    })
    .await
}

/// Wait for the broadcast of the todos source status reaching `state`. The hub
/// announces it a beat after it has finished applying the update, so once this
/// returns, everything the hub does for that update (including re-checking
/// picks) has run.
async fn wait_for_todos_status(rig: &mut Rig, state: SourceState) {
    recv_until(&mut rig.brx, |m| match m {
        ServerMsg::WorkSourceStatus { status } if status.source == WorkSource::Todos && status.state == state => {
            Some(())
        }
        _ => None,
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pick_whose_item_disappears_from_a_fresh_source_is_marked_done_and_stays_listed() {
    let mut rig = rig_with_three_picks().await;

    rig.ttx.send(Some(fresh(todos_without(&[2])))).unwrap();
    let frame = wait_for_done(&mut rig, "todo:2").await;

    assert_eq!(ids_of(&frame), vec!["todo:1", "todo:2", "todo:3"], "the done pick stays in the list, in place");
    assert!(pick(&frame, "todo:2").done_since);
    assert!(!pick(&frame, "todo:1").done_since, "items still present are untouched");
    assert!(!pick(&frame, "todo:3").done_since);
    assert_eq!(rig.hub.picks().snapshot(), frame);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_done_flag_is_written_to_the_picks_file() {
    let mut rig = rig_with_three_picks().await;

    rig.ttx.send(Some(fresh(todos_without(&[3])))).unwrap();
    wait_for_done(&mut rig, "todo:3").await;

    let path = rig.picks_path();
    wait_until("the picks file to record the flip", || {
        fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str::<PicksSnapshot>(&raw).ok())
            .is_some_and(|s| s.items.iter().any(|p| p.item_id == "todo:3" && p.done_since))
    })
    .await;
    let persisted = read_persisted(&path);
    assert!(!pick(&persisted, "todo:1").done_since);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pick_whose_item_is_still_there_stays_not_done_through_source_updates() {
    let mut rig = rig_with_three_picks().await;

    // A new fresh snapshot with different neighbours but all three picked todos.
    rig.ttx.send(Some(fresh(todos_without(&[4, 5, 6])))).unwrap();
    recv_until(&mut rig.brx, |m| match m {
        ServerMsg::WorkSnapshot { source: WorkSource::Todos, items, .. } if items.len() == 6 => Some(()),
        _ => None,
    })
    .await;
    // Let the hub's follow-up for that update land before looking.
    wait_until("the todos source to hold six items", || rig.hub.status(WorkSource::Todos).count == 6).await;

    let snap = rig.hub.picks().snapshot();
    assert!(snap.items.iter().all(|p| !p.done_since), "{snap:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_missing_item_does_not_count_as_done_while_its_source_is_stale() {
    let mut rig = rig_with_three_picks().await;

    // A failed read that still carries a list lacking todo:2: the source is stale.
    rig.ttx
        .send(Some(TeriTodosSnapshot {
            generated_at: Some(Utc::now()),
            items: todos_without(&[2]),
            stale: true,
            error: Some("database is locked".into()),
            not_configured: false,
        }))
        .unwrap();
    wait_for_todos_status(&mut rig, SourceState::Stale).await;

    let during = rig.hub.picks().snapshot();
    assert!(
        during.items.iter().all(|p| !p.done_since),
        "nothing may flip while the source is stale: {during:?}"
    );
    assert!(drain_picks(&mut rig.brx).iter().all(|s| s.items.iter().all(|p| !p.done_since)));

    // The same list, read cleanly later, is evidence: now it flips.
    rig.ttx.send(Some(fresh(todos_without(&[2])))).unwrap();
    let frame = wait_for_done(&mut rig, "todo:2").await;
    assert!(!pick(&frame, "todo:1").done_since && !pick(&frame, "todo:3").done_since);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_missing_item_does_not_count_as_done_while_its_source_is_unavailable() {
    let mut rig = rig_with_three_picks().await;

    rig.ttx.send(Some(TeriTodosSnapshot { not_configured: true, ..Default::default() })).unwrap();
    wait_for_todos_status(&mut rig, SourceState::NotConfigured).await;

    let snap = rig.hub.picks().snapshot();
    assert!(snap.items.iter().all(|p| !p.done_since), "{snap:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn when_a_healthy_source_becomes_empty_every_pick_from_it_is_done() {
    let mut rig = rig_with_three_picks().await;

    rig.ttx.send(Some(fresh(Vec::new()))).unwrap();
    wait_for_todos_status(&mut rig, SourceState::Empty).await;

    wait_until("every pick to be done", || rig.hub.picks().snapshot().items.iter().all(|p| p.done_since)).await;
    assert_eq!(rig.hub.picks().snapshot().items.len(), 3, "done picks stay listed");
}

// ── 4. persistence ────────────────────────────────────────────────────────────

fn store_at(path: Option<PathBuf>) -> (Arc<PicksStore>, broadcast::Receiver<ServerMsg>) {
    let (tx, rx) = broadcast::channel(64);
    (PicksStore::load(path, tx), rx)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn published_picks_survive_a_restart() {
    let rig = rig().await;
    let published = rig.hub.publish_picks(&entries(&["todo:3", "todo:1", "todo:2"])).unwrap();

    let (reloaded, _rx) = store_at(Some(rig.picks_path()));

    assert_eq!(reloaded.snapshot(), published);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stored_generating_flag_is_not_believed_after_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("picks.json");
    let stored = PicksSnapshot {
        generated_at: Some(Utc::now()),
        generating: true,
        unavailable_sources: vec![WorkSource::Jira],
        items: vec![nostromo::data::work::Pick {
            item_id: "todo:1".into(),
            source: WorkSource::Todos,
            title: "Write the quarterly report".into(),
            reason: "Due today".into(),
            done_since: false,
        }],
        error: None,
    };
    fs::write(&path, serde_json::to_string(&stored).unwrap()).unwrap();

    let (store, _rx) = store_at(Some(path));

    let loaded = store.snapshot();
    assert!(!loaded.generating, "a crash mid-generation must not leave the spinner on forever");
    assert_eq!(loaded.items, stored.items, "the picks themselves are kept");
    assert_eq!(loaded.generated_at, stored.generated_at);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_missing_or_corrupt_picks_file_loads_as_no_picks() {
    let dir = tempfile::tempdir().unwrap();

    let (missing, _rx) = store_at(Some(dir.path().join("nope.json")));
    assert_eq!(missing.snapshot(), PicksSnapshot::default());

    let corrupt_path = dir.path().join("corrupt.json");
    fs::write(&corrupt_path, "{ this is not json").unwrap();
    let (corrupt, _rx) = store_at(Some(corrupt_path));
    assert_eq!(corrupt.snapshot(), PicksSnapshot::default());

    let (in_memory, _rx) = store_at(None);
    assert_eq!(in_memory.snapshot(), PicksSnapshot::default());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_corrupt_file_does_not_stop_a_new_publish() {
    let rig = rig().await;
    fs::write(rig.picks_path(), "garbage").unwrap();
    let (store, _rx) = store_at(Some(rig.picks_path()));
    assert_eq!(store.snapshot(), PicksSnapshot::default());

    let published = store.publish(&entries(&["todo:1", "todo:2", "todo:3"]), &rig.hub).expect("publish works");

    assert_eq!(read_persisted(&rig.picks_path()), published);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn publishing_leaves_only_the_picks_file_behind() {
    let rig = rig().await;

    rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    rig.hub.publish_picks(&entries(&["todo:4", "todo:5", "todo:6"])).unwrap();

    let mut names: Vec<String> = fs::read_dir(rig.dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n != "code")
        .collect();
    names.sort();
    assert_eq!(names, vec!["picks.json"], "an atomic write leaves no temp file behind");
    assert!(serde_json::from_str::<PicksSnapshot>(&fs::read_to_string(rig.picks_path()).unwrap()).is_ok());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_in_memory_store_publishes_without_touching_disk() {
    let rig = rig().await;
    let (store, mut rx) = store_at(None);

    let snap = store.publish(&entries(&["todo:1", "todo:2", "todo:3"]), &rig.hub).unwrap();

    assert_eq!(store.snapshot(), snap);
    assert_eq!(drain_picks(&mut rx), vec![snap]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn broadcast_resends_the_current_picks_as_a_frame() {
    let rig = rig().await;
    let snap = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    let mut rx = rig.hub.context().broadcast_tx.subscribe();

    rig.hub.picks().broadcast();

    assert_eq!(recv_until(&mut rx, picks_frame).await, snap);
}

// ── 5. generation ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
enum Call {
    Spawn { tag: String, agent: String, cwd: PathBuf },
    Send { tag: String, text: String },
    Stop { tag: String },
}

#[derive(Default)]
struct FakeHost {
    calls: Mutex<Vec<Call>>,
    spawn_error: Mutex<Option<String>>,
    send_error: Mutex<Option<String>>,
    dead: AtomicBool,
    on_send: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

impl FakeHost {
    fn calls(&self) -> Vec<Call> {
        self.calls.lock().unwrap().clone()
    }
    fn count(&self, pred: impl Fn(&Call) -> bool) -> usize {
        self.calls().iter().filter(|c| pred(c)).count()
    }
    fn spawns(&self) -> usize {
        self.count(|c| matches!(c, Call::Spawn { .. }))
    }
    fn sends(&self) -> usize {
        self.count(|c| matches!(c, Call::Send { .. }))
    }
    fn stops(&self) -> usize {
        self.count(|c| matches!(c, Call::Stop { .. }))
    }
    fn on_send(&self, f: impl Fn() + Send + Sync + 'static) {
        *self.on_send.lock().unwrap() = Some(Arc::new(f));
    }
    fn clear_on_send(&self) {
        *self.on_send.lock().unwrap() = None;
    }
    /// Make the "agent" publish `ids` through the hub when it receives its prompt.
    fn publishes_on_send(&self, hub: &Arc<WorkHub>, ids: &'static [&'static str]) {
        let hub = hub.clone();
        self.on_send(move || {
            hub.publish_picks(&entries(ids)).expect("the fake agent's picks are valid");
        });
    }
}

impl PicksSessionHost for FakeHost {
    fn spawn(&self, tag: &str, agent: &str, cwd: &std::path::Path) -> Result<(), String> {
        self.calls.lock().unwrap().push(Call::Spawn { tag: tag.into(), agent: agent.into(), cwd: cwd.into() });
        match self.spawn_error.lock().unwrap().clone() {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }
    fn send(&self, tag: &str, text: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(Call::Send { tag: tag.into(), text: text.into() });
        if let Some(e) = self.send_error.lock().unwrap().clone() {
            return Err(e);
        }
        let hook = self.on_send.lock().unwrap().clone();
        if let Some(hook) = hook {
            hook();
        }
        Ok(())
    }
    fn is_alive(&self, _tag: &str) -> bool {
        !self.dead.load(Ordering::SeqCst)
    }
    fn stop(&self, tag: &str) {
        self.calls.lock().unwrap().push(Call::Stop { tag: tag.into() });
    }
}

fn generator(rig: &Rig, timeout: Duration) -> (Arc<FakeHost>, Arc<PicksGenerator>) {
    let host = Arc::new(FakeHost::default());
    let generator = PicksGenerator::new(rig.hub.picks().clone(), host.clone() as Arc<dyn PicksSessionHost>, timeout);
    (host, generator)
}

async fn refresh(generator: &Arc<PicksGenerator>, reason: &str) -> Result<(), nostromo::data::work::WorkError> {
    tokio::time::timeout(WAIT, generator.refresh(reason))
        .await
        .expect("refresh returns once the generation has started; it does not wait for it")
}

/// Wait until the generator is idle and the stored snapshot satisfies `ok`.
async fn wait_idle(rig: &Rig, generator: &Arc<PicksGenerator>, what: &str, ok: impl Fn(&PicksSnapshot) -> bool) {
    wait_until(what, || !generator.is_generating() && ok(&rig.hub.picks().snapshot())).await;
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").expect("HOME is set"))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_manual_refresh_runs_a_hidden_teri_session_and_ends_with_the_new_picks() {
    let mut rig = rig().await;
    let previous = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    let (host, generator) = generator(&rig, Duration::from_secs(120));
    host.publishes_on_send(&rig.hub, &["todo:7", "todo:8", "todo:9"]);
    drain_picks(&mut rig.brx);

    refresh(&generator, "manual").await.expect("a manual refresh starts a generation");

    let mut frames: Vec<PicksSnapshot> = Vec::new();
    let last = recv_until(&mut rig.brx, |m| {
        let snap = picks_frame(m)?;
        frames.push(snap.clone());
        (!snap.generating && ids_of(&snap) == vec!["todo:7", "todo:8", "todo:9"]).then_some(snap)
    })
    .await;

    assert!(frames.iter().any(|f| f.generating), "clients are told a generation is running: {frames:?}");
    for f in frames.iter().filter(|f| f.generating) {
        assert_eq!(ids_of(f), ids_of(&previous), "the previous picks stay visible while generating");
    }
    assert_eq!(last.error, None);
    assert!(!last.generating);

    wait_idle(&rig, &generator, "the generator to finish", |s| !s.generating).await;
    let calls = host.calls();
    assert_eq!(host.spawns(), 1, "{calls:?}");
    assert!(
        calls.contains(&Call::Spawn { tag: "teri-picks".into(), agent: "teri:teri".into(), cwd: home() }),
        "{calls:?}"
    );
    assert!(calls.contains(&Call::Send { tag: "teri-picks".into(), text: PICKS_PROMPT.to_string() }), "{calls:?}");
    assert_eq!(host.stops(), 1, "the hidden session is ended after the publish: {calls:?}");
    assert!(calls.contains(&Call::Stop { tag: "teri-picks".into() }));
    assert_eq!(rig.hub.picks().snapshot(), last);
    // Spawn precedes send precedes stop.
    let pos = |pred: &dyn Fn(&Call) -> bool| calls.iter().position(pred).unwrap();
    assert!(pos(&|c| matches!(c, Call::Spawn { .. })) < pos(&|c| matches!(c, Call::Send { .. })));
    assert!(pos(&|c| matches!(c, Call::Send { .. })) < pos(&|c| matches!(c, Call::Stop { .. })));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_first_open_refresh_also_generates() {
    let rig = rig().await;
    let (host, generator) = generator(&rig, Duration::from_secs(120));
    host.publishes_on_send(&rig.hub, &["todo:1", "todo:2", "todo:3"]);

    refresh(&generator, "first_open").await.expect("first_open starts a generation");

    wait_idle(&rig, &generator, "picks to be published", |s| s.items.len() == 3 && !s.generating).await;
    assert_eq!(host.spawns(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refresh_while_one_is_running_does_not_start_a_second_session() {
    let rig = rig().await;
    let previous = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    let (host, generator) = generator(&rig, Duration::from_secs(120));

    refresh(&generator, "manual").await.unwrap();
    wait_until("the prompt to be sent", || host.sends() == 1).await;
    assert!(generator.is_generating());
    assert!(rig.hub.picks().snapshot().generating);
    // `generating` is a live flag only: it never reaches the file.
    assert!(!read_persisted(&rig.picks_path()).generating);

    refresh(&generator, "manual").await.expect("a second request while generating is quietly ignored");
    refresh(&generator, "first_open").await.expect("so is another reason");

    assert_eq!(host.spawns(), 1);
    assert_eq!(host.sends(), 1);
    assert_eq!(host.stops(), 0, "the running session is left alone");
    assert!(generator.is_generating());

    // Finish it: the agent publishes.
    rig.hub.publish_picks(&entries(&["todo:4", "todo:5", "todo:6"])).unwrap();
    wait_idle(&rig, &generator, "the generation to end", |s| !s.generating).await;
    assert_eq!(host.stops(), 1);
    assert_eq!(host.spawns(), 1);
    assert_ne!(ids_of(&rig.hub.picks().snapshot()), ids_of(&previous));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn once_a_generation_has_ended_a_new_refresh_starts_a_new_session() {
    let rig = rig().await;
    let (host, generator) = generator(&rig, Duration::from_secs(120));
    host.publishes_on_send(&rig.hub, &["todo:1", "todo:2", "todo:3"]);

    refresh(&generator, "manual").await.unwrap();
    wait_idle(&rig, &generator, "the first generation", |s| s.items.len() == 3).await;
    refresh(&generator, "manual").await.unwrap();
    wait_until("the second session", || host.spawns() == 2).await;
    wait_idle(&rig, &generator, "the second generation", |s| !s.generating).await;

    assert_eq!(host.spawns(), 2);
    assert_eq!(host.stops(), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_generation_that_never_publishes_times_out_keeping_the_previous_picks() {
    let rig = rig().await;
    let previous = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    let (host, generator) = generator(&rig, Duration::from_millis(150));

    refresh(&generator, "manual").await.unwrap();

    wait_idle(&rig, &generator, "the timeout to be reported", |s| s.error.is_some() && !s.generating).await;
    let snap = rig.hub.picks().snapshot();
    let error = snap.error.clone().unwrap();
    assert!(error.starts_with("Picks refresh failed"), "{error}");
    assert_eq!(snap.items, previous.items, "the previous picks stay");
    assert_eq!(snap.generated_at, previous.generated_at);
    assert!(!snap.generating);
    assert!(host.stops() >= 1, "the session is stopped even though nothing was published: {:?}", host.calls());
    assert!(host.calls().iter().all(|c| match c {
        Call::Stop { tag } | Call::Send { tag, .. } | Call::Spawn { tag, .. } => tag == "teri-picks",
    }));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failure_is_broadcast_and_a_later_successful_publish_clears_it() {
    let mut rig = rig().await;
    rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    let (_host, generator) = generator(&rig, Duration::from_millis(150));
    drain_picks(&mut rig.brx);

    refresh(&generator, "manual").await.unwrap();
    let failed = recv_until(&mut rig.brx, |m| picks_frame(m).filter(|s| s.error.is_some())).await;
    assert!(failed.error.unwrap().starts_with("Picks refresh failed"));
    assert!(!failed.generating);
    wait_idle(&rig, &generator, "the generator to settle", |s| s.error.is_some()).await;

    let ok = rig.hub.publish_picks(&entries(&["todo:4", "todo:5", "todo:6"])).unwrap();

    assert_eq!(ok.error, None);
    assert_eq!(rig.hub.picks().snapshot().error, None);
    assert_eq!(read_persisted(&rig.picks_path()).error, None);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_that_cannot_be_started_fails_the_refresh_and_can_be_retried() {
    let rig = rig().await;
    let previous = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    let (host, generator) = generator(&rig, Duration::from_secs(120));
    *host.spawn_error.lock().unwrap() = Some("no such agent: teri:teri".into());

    refresh(&generator, "manual").await.expect("the refresh itself is accepted");

    wait_idle(&rig, &generator, "the failure to be reported", |s| s.error.is_some()).await;
    let snap = rig.hub.picks().snapshot();
    let error = snap.error.clone().unwrap();
    assert!(error.starts_with("Picks refresh failed: "), "{error}");
    assert!(error.contains("no such agent: teri:teri"), "{error}");
    assert_eq!(snap.items, previous.items);
    assert!(!snap.generating);
    assert_eq!(host.sends(), 0, "nothing is sent to a session that did not start");
    assert!(host.stops() >= 1, "stop is still called after a failed spawn: {:?}", host.calls());

    // The failure does not wedge the generator.
    *host.spawn_error.lock().unwrap() = None;
    host.publishes_on_send(&rig.hub, &["todo:4", "todo:5", "todo:6"]);
    refresh(&generator, "manual").await.unwrap();
    wait_idle(&rig, &generator, "the retry to publish", |s| s.error.is_none() && s.items.len() == 3 && ids_of(s) != ids_of(&previous)).await;
    assert_eq!(host.spawns(), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_prompt_that_cannot_be_delivered_fails_the_refresh_stops_the_session_and_can_be_retried() {
    let rig = rig().await;
    let previous = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    let (host, generator) = generator(&rig, Duration::from_secs(120));
    *host.send_error.lock().unwrap() = Some("session went away".into());

    refresh(&generator, "manual").await.unwrap();

    wait_idle(&rig, &generator, "the failure to be reported", |s| s.error.is_some()).await;
    let snap = rig.hub.picks().snapshot();
    let error = snap.error.clone().unwrap();
    assert!(error.starts_with("Picks refresh failed: "), "{error}");
    assert!(error.contains("session went away"), "{error}");
    assert_eq!(snap.items, previous.items);
    assert!(!snap.generating);
    assert!(host.stops() >= 1, "{:?}", host.calls());

    *host.send_error.lock().unwrap() = None;
    host.clear_on_send();
    host.publishes_on_send(&rig.hub, &["todo:4", "todo:5", "todo:6"]);
    refresh(&generator, "manual").await.unwrap();
    wait_idle(&rig, &generator, "the retry to publish", |s| s.error.is_none() && ids_of(s) != ids_of(&previous)).await;
    assert_eq!(host.spawns(), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_that_dies_before_publishing_fails_the_refresh_without_waiting_for_the_timeout() {
    let rig = rig().await;
    let previous = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    // A timeout long enough that only the liveness check can end this in time.
    let (host, generator) = generator(&rig, Duration::from_secs(300));
    let dead = host.clone();
    host.on_send(move || dead.dead.store(true, Ordering::SeqCst));

    refresh(&generator, "manual").await.unwrap();

    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    while generator.is_generating() || rig.hub.picks().snapshot().error.is_none() {
        assert!(tokio::time::Instant::now() < deadline, "a dead session must fail the refresh early");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let snap = rig.hub.picks().snapshot();
    assert!(snap.error.unwrap().starts_with("Picks refresh failed"));
    assert_eq!(snap.items, previous.items);
    assert!(!snap.generating);
    assert!(host.stops() >= 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn retention_lag_only_re_announces_the_current_picks() {
    let mut rig = rig().await;
    let snap = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).unwrap();
    let (host, generator) = generator(&rig, Duration::from_secs(120));
    drain_picks(&mut rig.brx);

    refresh(&generator, "retention_lag").await.expect("retention_lag is accepted");

    let frame = recv_until(&mut rig.brx, picks_frame).await;
    assert_eq!(frame, snap);
    assert!(!generator.is_generating());
    assert_eq!(host.spawns(), 0);
    assert!(host.calls().is_empty(), "{:?}", host.calls());
    assert!(!rig.hub.picks().snapshot().generating);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unknown_refresh_reason_is_refused_without_starting_anything() {
    let mut rig = rig().await;
    let (host, generator) = generator(&rig, Duration::from_secs(120));
    drain_picks(&mut rig.brx);

    let err = refresh(&generator, "because_i_said_so").await.unwrap_err();

    assert_eq!(err.code, "invalid_argument");
    assert!(!generator.is_generating());
    assert!(host.calls().is_empty(), "{:?}", host.calls());
    assert!(drain_picks(&mut rig.brx).is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_publish_with_no_generation_running_is_accepted_and_starts_nothing() {
    let rig = rig().await;
    let (host, generator) = generator(&rig, Duration::from_secs(120));

    let snap = rig.hub.publish_picks(&entries(&["todo:1", "todo:2", "todo:3"])).expect("an unprompted publish is fine");

    assert_eq!(rig.hub.picks().snapshot(), snap);
    assert!(!generator.is_generating());
    assert!(host.calls().is_empty(), "{:?}", host.calls());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hub_without_a_session_host_cannot_generate_but_says_so() {
    let rig = rig().await;

    let err = rig.hub.refresh_picks("manual").await.unwrap_err();

    assert_eq!(err.code, "not_available");
    assert!(!rig.hub.picks().snapshot().generating);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_hub_routes_refresh_requests_to_the_session_host_it_was_given() {
    let host = Arc::new(FakeHost::default());
    let h = host.clone();
    let rig = rig_with(move |deps| {
        deps.picks_host = Some(h as Arc<dyn PicksSessionHost>);
        deps.picks_timeout = Some(Duration::from_secs(120));
    })
    .await;
    host.publishes_on_send(&rig.hub, &["todo:2", "todo:4", "todo:6"]);

    rig.hub.refresh_picks("manual").await.expect("the hub starts a generation");

    wait_until("the hub's generation to publish", || {
        let s = rig.hub.picks().snapshot();
        !s.generating && ids_of(&s) == vec!["todo:2", "todo:4", "todo:6"]
    })
    .await;
    wait_until("the session to be stopped", || host.stops() == 1).await;
    assert_eq!(host.spawns(), 1);
    assert!(host.calls().contains(&Call::Send { tag: "teri-picks".into(), text: PICKS_PROMPT.to_string() }));
}

// ── 6. MCP ────────────────────────────────────────────────────────────────────

fn mcp_state(rig: &Rig) -> McpSharedState {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let mut state = McpSharedState::for_test(event_tx);
    state.work_hub = Some(rig.hub.clone());
    state
}

fn picks_args(ids: &[&str]) -> Value {
    json!({
        "picks": ids.iter().map(|id| json!({"item_id": id, "reason": format!("Because {id} is next")})).collect::<Vec<_>>()
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn publishing_through_the_tool_broadcasts_the_retained_picks_and_get_picks_returns_them() {
    let mut rig = rig().await;
    let state = mcp_state(&rig);

    let out = publish_picks(&state, &picks_args(&["todo:2", "todo:1", "todo:3"]));

    assert_eq!(out["ok"], true, "{out}");
    let frame = tokio::time::timeout(WAIT, recv_until(&mut rig.brx, picks_frame))
        .await
        .expect("a TeriPicks frame is broadcast");
    assert_eq!(ids_of(&frame), vec!["todo:2", "todo:1", "todo:3"]);
    assert_eq!(frame.items[0].title, "Fix payment webhook");
    assert_eq!(out["picks"], serde_json::to_value(&frame).unwrap(), "the tool echoes the stored snapshot");

    let got = get_picks(&state);
    assert_eq!(got, serde_json::to_value(&frame).unwrap());
    assert_eq!(got["items"].as_array().unwrap().len(), 3);
    assert_eq!(got["items"][0]["item_id"], "todo:2");
    assert_eq!(got["items"][0]["source"], "todos");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_invalid_publish_returns_invalid_picks_naming_the_bad_id_and_broadcasts_nothing() {
    let mut rig = rig().await;
    let state = mcp_state(&rig);
    let before = rig.hub.picks().snapshot();
    drain_picks(&mut rig.brx);

    let out = publish_picks(&state, &picks_args(&["todo:1", "todo:2", "todo:12345"]));

    assert_eq!(out["error"], "invalid_picks", "{out}");
    assert!(out["message"].as_str().unwrap().contains("todo:12345"), "{out}");
    assert!(out.get("ok").is_none());
    assert!(drain_picks(&mut rig.brx).is_empty());
    assert_eq!(rig.hub.picks().snapshot(), before);
    assert_eq!(get_picks(&state), serde_json::to_value(&before).unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_wrong_count_through_the_tool_is_an_invalid_picks_error() {
    let rig = rig().await;
    let state = mcp_state(&rig);

    let out = publish_picks(&state, &picks_args(&["todo:1", "todo:2"]));

    assert_eq!(out["error"], "invalid_picks", "{out}");
    assert!(out["message"].as_str().unwrap().contains('2'), "the message says how many were sent: {out}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_publish_arguments_are_invalid_argument_errors() {
    let rig = rig().await;
    let state = mcp_state(&rig);
    let bad_args = [
        json!({}),
        json!(null),
        json!({"picks": "todo:1"}),
        json!({"picks": {"item_id": "todo:1", "reason": "x"}}),
        json!({"picks": [{"item_id": "todo:1"}, {"item_id": "todo:2", "reason": "r"}, {"item_id": "todo:3", "reason": "r"}]}),
        json!({"picks": [{"reason": "r"}, {"item_id": "todo:2", "reason": "r"}, {"item_id": "todo:3", "reason": "r"}]}),
        json!({"picks": [{"item_id": 1, "reason": "r"}, {"item_id": "todo:2", "reason": "r"}, {"item_id": "todo:3", "reason": "r"}]}),
    ];
    for args in bad_args {
        let out = publish_picks(&state, &args);

        assert_eq!(out["error"], "invalid_argument", "args {args} gave {out}");
        assert!(out["message"].is_string(), "{out}");
    }
    assert!(rig.hub.picks().snapshot().items.is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn without_a_hub_the_picks_tools_say_they_are_not_available() {
    let (event_tx, _rx) = mpsc::unbounded_channel();
    let state = McpSharedState::for_test(event_tx);
    assert!(state.work_hub.is_none());

    let published = publish_picks(&state, &picks_args(&["todo:1", "todo:2", "todo:3"]));
    let got = get_picks(&state);

    assert_eq!(published["error"], "not_available", "{published}");
    assert_eq!(got["error"], "not_available", "{got}");
}

fn unwrap_tool_json(result: ToolResult) -> Value {
    match result {
        ToolResult::Ok(content) => {
            let text = content[0]["text"].as_str().expect("text content").to_string();
            serde_json::from_str(&text).expect("the tool returns JSON text")
        }
        ToolResult::UnknownTool(name) => panic!("unknown tool {name}"),
        ToolResult::Forbidden(name) => panic!("tool {name} forbidden"),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_picks_tools_are_listed_and_dispatchable_by_name() {
    let names: Vec<String> =
        tool_descriptors().iter().filter_map(|d| d["name"].as_str().map(String::from)).collect();
    assert!(names.contains(&"teri.publish_picks".to_string()), "{names:?}");
    assert!(names.contains(&"teri.get_picks".to_string()), "{names:?}");

    let mut rig = rig().await;
    let state = mcp_state(&rig);

    let args = picks_args(&["todo:4", "todo:5", "todo:6"]);
    let published = unwrap_tool_json(dispatch("teri.publish_picks", Some(&args), &state, None).await);
    assert_eq!(published["ok"], true, "{published}");
    let frame = recv_until(&mut rig.brx, picks_frame).await;
    assert_eq!(ids_of(&frame), vec!["todo:4", "todo:5", "todo:6"]);

    let got = unwrap_tool_json(dispatch("teri.get_picks", None, &state, None).await);
    assert_eq!(got, serde_json::to_value(&frame).unwrap());

    let bad = json!({"picks": []});
    let rejected = unwrap_tool_json(dispatch("teri.publish_picks", Some(&bad), &state, None).await);
    assert_eq!(rejected["error"], "invalid_picks", "{rejected}");
}
