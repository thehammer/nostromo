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
use nostromo::ipc::protocol::{FocusMeta, ServerMsg};
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
        nonce: None,
    }
}

/// What the Mac pushes (and the daemon keeps) for a focus.
fn registry_meta(tag: &str) -> FocusMeta {
    FocusMeta {
        tag: tag.into(),
        display_name: tag.into(),
        agent_name: "cody".into(),
        project_name: None,
        org: None,
        is_built_in: false,
        session_summary: None,
        label: None,
        project_path: None,
        select_for_client: None,
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

// A restarted daemon has no sessions until the Mac reconnects and pushes its
// focus registry; in that window an item sent before the restart must still
// show as sent.

#[tokio::test]
async fn a_focus_known_only_from_the_pushed_registry_shows_sent_before_its_session_is_back() {
    let rig = Rig::new(|ledger, sessions| {
        sessions.lock().unwrap().set_focus_registry(vec![registry_meta("cody-restarted")]);
        assert!(!sessions.lock().unwrap().has_live_session("cody-restarted"), "precondition: no session yet");
        ledger.record("todo:1", marker("focus", "cody-restarted")).unwrap();
    })
    .await;
    wait_until_items_loaded(&rig).await;

    let sent = rig.item("todo:1").sent;
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0].target_id, "cody-restarted");
    assert!(rig.item("todo:2").sent.is_empty());
}

#[tokio::test]
async fn a_marker_whose_tag_is_neither_running_nor_registered_is_not_shown_even_with_a_registry() {
    let rig = Rig::new(|ledger, sessions| {
        sessions.lock().unwrap().set_focus_registry(vec![registry_meta("cody-someone-else")]);
        ledger.record("todo:1", marker("focus", "cody-gone")).unwrap();
    })
    .await;
    wait_until_items_loaded(&rig).await;
    assert!(rig.item("todo:1").sent.is_empty());
}

#[tokio::test]
async fn a_focus_stopped_in_this_process_stops_showing_sent_even_though_the_registry_still_lists_it() {
    let mut rig = Rig::new(|ledger, sessions| {
        Rig::spawn_live(sessions, "cody-stopped-listed");
        sessions.lock().unwrap().set_focus_registry(vec![registry_meta("cody-stopped-listed")]);
        ledger.record("todo:1", marker("focus", "cody-stopped-listed")).unwrap();
    })
    .await;
    rig.next_snapshot(|items| !sent_of(items, "todo:1").is_empty()).await;

    rig.sessions.lock().unwrap().stop("cody-stopped-listed");
    assert!(
        rig.sessions.lock().unwrap().focus_registry().iter().any(|f| f.tag == "cody-stopped-listed"),
        "precondition: the registry still lists the closed focus"
    );
    // Make the hub look now (it also re-checks on a timer).
    rig.ledger.record("todo:2", marker("focus", "some-dead-focus")).unwrap();

    rig.next_snapshot(|items| sent_of(items, "todo:1").is_empty()).await;
    assert!(rig.item("todo:1").sent.is_empty());
}

// ─────────────────────────────────────────────────────────────────────────────
// The periodic prune must not forget live work it cannot see
//
// A restarted daemon has no sessions and an empty registry until the Mac has
// pushed one. "Not registered" means nothing until then, so a focus marker is
// pruned only once the daemon can vouch for a registry (two non-empty pushes
// since the last empty one) that lacks the tag, with no live session either.
// ─────────────────────────────────────────────────────────────────────────────

fn push(sessions: &Mutex<SessionManager>, tags: &[&str]) {
    sessions.lock().unwrap().set_focus_registry(tags.iter().map(|t| registry_meta(t)).collect());
}

fn tags_in_ledger(ledger: &SentLedger, item: &str) -> Vec<String> {
    let mut tags: Vec<String> = ledger.markers(item).into_iter().map(|m| m.target_id).collect();
    tags.sort();
    tags
}

#[tokio::test]
async fn a_prune_before_the_mac_has_pushed_a_registry_keeps_every_focus_marker() {
    let rig = Rig::new(|ledger, sessions| {
        ledger.record("todo:1", marker("focus", "cody-after-restart")).unwrap();
        let mgr = sessions.lock().unwrap();
        assert!(!mgr.has_live_session("cody-after-restart"), "precondition: no session");
        assert!(mgr.focus_registry().is_empty(), "precondition: nothing pushed");
    })
    .await;

    rig.hub.prune_sent().await;

    assert_eq!(tags_in_ledger(&rig.ledger, "todo:1"), vec!["cody-after-restart".to_string()]);
    assert_eq!(
        tags_in_ledger(&SentLedger::new(rig.ledger.path()), "todo:1"),
        vec!["cody-after-restart".to_string()],
        "and the file still has it"
    );
}

#[tokio::test]
async fn once_two_pushes_agree_a_prune_drops_only_the_focus_markers_the_registry_lacks() {
    let rig = Rig::new(|ledger, sessions| {
        Rig::spawn_live(sessions, "cody-running");
        ledger.record("todo:1", marker("focus", "cody-gone")).unwrap();
        ledger.record("todo:1", marker("focus", "cody-listed")).unwrap();
        ledger.record("todo:2", marker("focus", "cody-running")).unwrap();
        ledger.record("todo:2", marker("focus", "cody-pending")).unwrap();
        push(sessions, &["cody-listed", "cody-pending", "cody-other"]);
        // `cody-pending` is omitted by the latest push only: a second push has to
        // agree before it is gone.
        push(sessions, &["cody-listed", "cody-other"]);
        assert!(sessions.lock().unwrap().registry_known(), "precondition");
    })
    .await;

    rig.hub.prune_sent().await;

    assert_eq!(
        tags_in_ledger(&rig.ledger, "todo:1"),
        vec!["cody-listed".to_string()],
        "a tag the known registry lacks, with no session, is gone"
    );
    assert_eq!(
        tags_in_ledger(&rig.ledger, "todo:2"),
        vec!["cody-pending".to_string(), "cody-running".to_string()],
        "a live session and a pending departure both survive"
    );
    assert_eq!(
        tags_in_ledger(&SentLedger::new(rig.ledger.path()), "todo:1"),
        vec!["cody-listed".to_string()],
        "the prune is persisted"
    );
}

#[tokio::test]
async fn a_focus_marker_whose_tag_was_reused_by_a_later_focus_is_pruned_even_with_the_tag_registered() {
    let rig = Rig::new(|ledger, sessions| {
        let mut old = marker("focus", "cody-reused");
        old.nonce = Some("old-focus".into());
        ledger.record("todo:1", old).unwrap();
        sessions.lock().unwrap().set_focus_nonce("cody-reused", "new-focus".into());
        push(sessions, &["cody-reused"]);
        push(sessions, &["cody-reused"]);
    })
    .await;

    rig.hub.prune_sent().await;

    assert!(rig.ledger.markers("todo:1").is_empty(), "the marker belongs to a focus that is gone");
}

#[tokio::test]
async fn an_empty_push_makes_the_registry_unknown_again_so_a_prune_keeps_the_markers() {
    let rig = Rig::new(|ledger, sessions| {
        ledger.record("todo:1", marker("focus", "cody-a")).unwrap();
        ledger.record("todo:2", marker("focus", "cody-b")).unwrap();
        push(sessions, &["cody-a"]);
        push(sessions, &["cody-a"]);
        // A client that reconnected before it had loaded anything.
        push(sessions, &[]);
        assert!(!sessions.lock().unwrap().registry_known(), "precondition");
    })
    .await;

    rig.hub.prune_sent().await;

    assert_eq!(tags_in_ledger(&rig.ledger, "todo:1"), vec!["cody-a".to_string()]);
    assert_eq!(tags_in_ledger(&rig.ledger, "todo:2"), vec!["cody-b".to_string()], "not registered, but nothing vouches for that");
}

#[tokio::test]
async fn a_single_non_empty_push_is_not_enough_to_prune_on() {
    let rig = Rig::new(|ledger, sessions| {
        ledger.record("todo:1", marker("focus", "cody-not-in-the-first-push")).unwrap();
        push(sessions, &["cody-someone-else"]);
        assert!(!sessions.lock().unwrap().registry_known(), "precondition");
    })
    .await;

    rig.hub.prune_sent().await;

    assert_eq!(tags_in_ledger(&rig.ledger, "todo:1"), vec!["cody-not-in-the-first-push".to_string()]);
}

// ── Mother job markers made while `mother list` is running ───────────────────

/// Sets an env var for the test and restores the previous value, even on panic.
struct EnvVar(&'static str, Option<std::ffi::OsString>);

impl EnvVar {
    fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> EnvVar {
        let prev = std::env::var_os(key);
        std::env::set_var(key, value);
        EnvVar(key, prev)
    }
}

impl Drop for EnvVar {
    fn drop(&mut self) {
        match self.1.take() {
            Some(v) => std::env::set_var(self.0, v),
            None => std::env::remove_var(self.0),
        }
    }
}

/// `list` announces itself, then blocks until a `release` file exists (bounded
/// in the script itself) and answers with one job, `job-listed`.
const BLOCKING_LIST_MOTHER: &str = r#"#!/bin/sh
here="$(dirname "$0")"
if [ "$1" = "list" ]; then
  echo started > "$here/list-started"
  i=0
  while [ ! -e "$here/release" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done
  printf '[{"id":"job-listed","state":"queued"}]'
  exit 0
fi
echo "mother: unexpected command: $1" >&2
exit 2
"#;

async fn wait_for_file(path: &std::path::Path, what: &str) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !path.exists() {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn a_job_recorded_while_mother_is_being_listed_survives_the_prune_that_could_not_see_it() {
    use std::os::unix::fs::PermissionsExt;

    let rig = Rig::new(|ledger, _| {
        let long_ago = Utc::now() - chrono::Duration::hours(1);
        let mut old = marker("mother_job", "job-archived");
        old.created_at = long_ago;
        ledger.record("todo:1", old).unwrap();
        let mut listed = marker("mother_job", "job-listed");
        listed.created_at = long_ago;
        ledger.record("todo:1", listed).unwrap();
    })
    .await;

    let mother_dir = rig._dir.path().join("fake-mother");
    std::fs::create_dir_all(&mother_dir).unwrap();
    let script = mother_dir.join("mother");
    std::fs::write(&script, BLOCKING_LIST_MOTHER).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _mother = EnvVar::set("MOTHER_BIN", &script);

    let hub = Arc::clone(&rig.hub);
    let prune = tokio::spawn(async move { hub.prune_sent().await });

    // The prune is now inside `mother list`. A job queued and recorded at this
    // moment is in the ledger but cannot be in the list it is about to get.
    wait_for_file(&mother_dir.join("list-started"), "the prune to ask Mother for its jobs").await;
    rig.ledger.record("todo:2", marker("mother_job", "job-just-queued")).unwrap();
    std::fs::write(mother_dir.join("release"), "").unwrap();

    tokio::time::timeout(WAIT, prune).await.expect("the prune finishes once Mother answers").unwrap();

    assert_eq!(
        tags_in_ledger(&rig.ledger, "todo:2"),
        vec!["job-just-queued".to_string()],
        "a job recorded after the prune started listing must not be pruned for being absent from that list"
    );
    assert_eq!(
        tags_in_ledger(&rig.ledger, "todo:1"),
        vec!["job-listed".to_string()],
        "an old job Mother no longer lists is pruned; one it still lists is kept"
    );
}
