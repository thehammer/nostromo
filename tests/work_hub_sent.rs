//! The work hub and the sent ledger: an item sent to a live focus shows
//! `sent`, one whose focus is gone does not, and clients are told (a fresh
//! `WorkSnapshot`) when a marker dies.
//!
//! Behavioural only. A fake `claude` gives the session manager a real live
//! session. Waits are bounded and event-driven, never wall-clock assertions.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use chrono::Utc;
use nostromo::data::teri_todos::{TeriTodo, TeriTodosSnapshot};
use nostromo::data::work::hub::{HubDeps, WorkHub};
use nostromo::data::work::query::WorkFilter;
use nostromo::data::work::sent::{install_ledger, SentLedger};
use nostromo::data::work::{SentMarker, WorkItem, WorkSource};
use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::session_manager::CLAUDE_BIN_ENV;
use nostromo::ipc::SessionManager;
use tokio::sync::{broadcast, watch};

const WAIT: Duration = Duration::from_secs(20);

/// Serializes tests: the ledger is process-global.
static LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

const FAKE_CLAUDE_SCRIPT: &str = r#"#!/bin/sh
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0.01}'
while IFS= read -r line; do
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0.01}'
done
"#;

static FAKE_CLAUDE_DIR: OnceLock<PathBuf> = OnceLock::new();

fn install_fake_claude() {
    FAKE_CLAUDE_DIR.get_or_init(|| {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("nostromo-fake-claude-hubsent-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("fake claude dir");
        let script = dir.join("claude");
        std::fs::write(&script, FAKE_CLAUDE_SCRIPT).expect("write fake claude");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        std::env::set_var(CLAUDE_BIN_ENV, &script);
        dir
    });
}

fn marker(kind: &str, target: &str) -> SentMarker {
    SentMarker {
        kind: kind.into(),
        target_id: target.into(),
        label: format!("label {target}"),
        created_at: Utc::now(),
    }
}

fn snapshot(titles: &[(i64, &str)]) -> TeriTodosSnapshot {
    TeriTodosSnapshot {
        generated_at: Some(Utc::now()),
        items: titles
            .iter()
            .map(|(id, t)| TeriTodo {
                id: *id,
                title: (*t).into(),
                status: "open".into(),
                priority: 2,
                due_date: None,
                jira_key: None,
                body: None,
            })
            .collect(),
        ..Default::default()
    }
}

struct Rig {
    _guard: tokio::sync::MutexGuard<'static, ()>,
    _dir: tempfile::TempDir,
    ledger: Arc<SentLedger>,
    sessions: Arc<Mutex<SessionManager>>,
    hub: Arc<WorkHub>,
    rx: broadcast::Receiver<ServerMsg>,
    _todos_tx: watch::Sender<Option<TeriTodosSnapshot>>,
}

impl Drop for Rig {
    fn drop(&mut self) {
        // The sessions' reader threads live in the runtime's blocking pool: end
        // the children or dropping the runtime waits for them forever.
        self.sessions.lock().unwrap_or_else(|e| e.into_inner()).kill_all_on_shutdown();
    }
}

impl Rig {
    /// A hub over todos 1 and 2, with the ledger and session manager wired in.
    /// `before` runs after the ledger is installed and before the hub starts.
    async fn new(before: impl FnOnce(&SentLedger, &Mutex<SessionManager>)) -> Rig {
        let guard = LOCK.lock().await;
        install_fake_claude();
        let dir = tempfile::tempdir().unwrap();
        let ledger = Arc::new(SentLedger::new(dir.path().join("sent.json")));
        install_ledger(Arc::clone(&ledger));
        let sessions = Arc::new(Mutex::new(SessionManager::with_store_path(dir.path().join("sessions.json"))));
        before(&ledger, &sessions);

        let (btx, rx) = broadcast::channel(1024);
        let (ttx, trx) = watch::channel(Some(snapshot(&[(1, "First todo"), (2, "Second todo")])));
        let hub = WorkHub::spawn(HubDeps {
            session_mgr: Some(Arc::clone(&sessions)),
            ..HubDeps::new(btx, trx)
        });
        Rig { _guard: guard, _dir: dir, ledger, sessions, hub, rx, _todos_tx: ttx }
    }

    fn spawn_live(sessions: &Mutex<SessionManager>, tag: &str) {
        sessions
            .lock()
            .unwrap()
            .spawn_session(tag.into(), "cody".into(), tag.into(), None, None, false)
            .expect("fake claude spawns");
    }

    fn items(&self) -> Vec<WorkItem> {
        self.hub.items(&WorkFilter::default())
    }

    fn item(&self, id: &str) -> WorkItem {
        self.items().into_iter().find(|i| i.id == id).unwrap_or_else(|| panic!("no item {id}"))
    }

    /// Next todos snapshot satisfying `pred`, within `WAIT`.
    async fn next_snapshot(&mut self, pred: impl Fn(&[WorkItem]) -> bool) -> Vec<WorkItem> {
        let deadline = tokio::time::Instant::now() + WAIT;
        loop {
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            match tokio::time::timeout(left, self.rx.recv()).await {
                Err(_) => panic!("timed out waiting for the expected WorkSnapshot"),
                Ok(Ok(ServerMsg::WorkSnapshot { source: WorkSource::Todos, items, .. })) if pred(&items) => {
                    return items
                }
                Ok(Ok(_)) | Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(broadcast::error::RecvError::Closed)) => panic!("broadcast closed"),
            }
        }
    }
}

fn sent_of<'a>(items: &'a [WorkItem], id: &str) -> &'a [SentMarker] {
    &items.iter().find(|i| i.id == id).unwrap_or_else(|| panic!("no item {id}")).sent
}

async fn wait_until_items_loaded(rig: &Rig) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while rig.items().len() < 2 {
        assert!(tokio::time::Instant::now() < deadline, "hub never loaded the todos");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn an_item_sent_to_a_live_focus_shows_sent_and_an_unsent_one_does_not() {
    let rig = Rig::new(|ledger, sessions| {
        Rig::spawn_live(sessions, "cody-first");
        ledger.record("todo:1", marker("focus", "cody-first")).unwrap();
    })
    .await;
    wait_until_items_loaded(&rig).await;

    let sent = rig.item("todo:1").sent;
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].target_id, "cody-first");
    assert!(rig.item("todo:2").sent.is_empty());
}

#[tokio::test]
async fn a_marker_whose_focus_has_no_live_session_is_not_shown() {
    let rig = Rig::new(|ledger, _| {
        ledger.record("todo:1", marker("focus", "cody-never-ran")).unwrap();
    })
    .await;
    wait_until_items_loaded(&rig).await;
    assert!(rig.item("todo:1").sent.is_empty());
}

#[tokio::test]
async fn sending_an_item_after_the_hub_is_up_republishes_it_with_sent() {
    let mut rig = Rig::new(|_, sessions| Rig::spawn_live(sessions, "cody-late")).await;
    wait_until_items_loaded(&rig).await;

    rig.ledger.record("todo:2", marker("focus", "cody-late")).unwrap();

    let items = rig.next_snapshot(|items| !sent_of(items, "todo:2").is_empty()).await;
    assert_eq!(sent_of(&items, "todo:2")[0].target_id, "cody-late");
    assert!(sent_of(&items, "todo:1").is_empty());
    assert_eq!(rig.item("todo:2").sent.len(), 1);
}

#[tokio::test]
async fn closing_the_focus_clears_sent_and_clients_get_a_fresh_snapshot() {
    let mut rig = Rig::new(|ledger, sessions| {
        Rig::spawn_live(sessions, "cody-closing");
        ledger.record("todo:1", marker("focus", "cody-closing")).unwrap();
    })
    .await;
    rig.next_snapshot(|items| !sent_of(items, "todo:1").is_empty()).await;

    rig.sessions.lock().unwrap().stop("cody-closing");
    // The hub also re-checks on a short timer; a ledger change is the prompt
    // way to make it look now, whichever happens first.
    rig.ledger.record("todo:2", marker("focus", "some-dead-focus")).unwrap();

    let items = rig.next_snapshot(|items| sent_of(items, "todo:1").is_empty()).await;
    assert!(sent_of(&items, "todo:2").is_empty(), "a dead marker never shows");
    assert!(rig.item("todo:1").sent.is_empty());
}
