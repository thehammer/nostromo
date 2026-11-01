//! Who starts a turn when the CLI wakes the agent for a finished background
//! task or a Monitor event (BA6a): the turn hook, the broadcast deltas and the
//! session state around a `<task-notification>` user event.
//!
//! Contract under test:
//!
//! * a notification the CLI sends on its own is a turn the CLI began: the hook
//!   hears `Started { author: Cli }`, the broadcast `TurnStarted` keeps the
//!   `task_wake` origin, the session is mid-turn until the result and idle
//!   after it;
//! * a message the user wrote while idle is not the author of a wake that
//!   arrives before its echo: the wake stays the CLI's and the user's own
//!   turn afterwards is the user's;
//! * a user or injected message whose own text starts with
//!   `<task-notification>` is that writer's turn, and its wake origin is
//!   taken back before the delta is broadcast;
//! * a message sent during a wake turn queues and is written only after the
//!   wake turn's result;
//! * two notifications with no reply between merge into one turn: one
//!   `TurnOrigin` event carrying both items, and no second `TurnStarted`.
//!
//! Sessions are stub `sh -c` children, as in `notice_inject_tests.rs`.

use super::*;
use crate::ipc::stream_json::{TaskWakeItem, Turn};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// ── rig (copied from notice_inject_tests.rs) ──────────────────────────────────

fn tmp_store() -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!("nostromo-wake-test-{}.json", Uuid::new_v4()));
    p
}

/// A stub session running `script` (its stdout is read as stream-json).
fn spawn_stub(mgr: &mut SessionManager, tag: &str, script: &str) {
    let program = PathBuf::from("/bin/sh");
    let args = vec!["-c".to_string(), script.to_string()];
    let managed = mgr
        .spawn_managed(
            tag.to_string(),
            "agent".into(),
            "View".into(),
            None,
            false,
            "stub-sid".into(),
            false,
            program.clone(),
            args.clone(),
            Some((program, args)),
        )
        .expect("spawn stub");
    mgr.sessions.insert(tag.to_string(), managed);
}

/// Poll `probe` until it gives a value (generous deadline, no fixed sleep
/// before asserting).
async fn eventually<T>(what: &str, mut probe: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(v) = probe() {
            return v;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

async fn wait_for_file(path: &Path, needle: &str) -> String {
    eventually(&format!("{needle:?} in {}", path.display()), || {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        text.contains(needle).then_some(text)
    })
    .await
}

fn queued(mgr: &SessionManager, tag: &str) -> Vec<String> {
    mgr.sessions[tag]
        .shared
        .pending
        .lock()
        .unwrap()
        .iter()
        .map(|m| m.text.clone())
        .collect()
}

type Heard = Arc<Mutex<Vec<(String, TurnEvent)>>>;

fn record_turns(mgr: &mut SessionManager) -> Heard {
    let heard: Heard = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&heard);
    mgr.set_turn_hook(Arc::new(move |tag: &str, event: &TurnEvent| {
        sink.lock().unwrap().push((tag.to_owned(), event.clone()));
    }));
    heard
}

fn heard_by(heard: &Heard, tag: &str) -> Vec<TurnEvent> {
    heard
        .lock()
        .unwrap()
        .iter()
        .filter(|(t, _)| t == tag)
        .map(|(_, e)| e.clone())
        .collect()
}

async fn wait_for_events(heard: &Heard, tag: &str, n: usize) -> Vec<TurnEvent> {
    eventually(&format!("{n} turn events for {tag}"), || {
        let seen = heard_by(heard, tag);
        (seen.len() >= n).then_some(seen)
    })
    .await
}

/// Everything a session broadcasts, accumulated as it arrives.
struct Feed {
    rx: tokio::sync::broadcast::Receiver<SessionEvent>,
    seen: Vec<SessionEvent>,
}

impl Feed {
    fn of(mgr: &SessionManager, tag: &str) -> Self {
        Feed {
            rx: mgr.sessions[tag].shared.event_tx.subscribe(),
            seen: Vec::new(),
        }
    }

    fn drain(&mut self) {
        loop {
            match self.rx.try_recv() {
                Ok(ev) => self.seen.push(ev),
                Err(tokio::sync::broadcast::error::TryRecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    }

    /// Wait until `done` holds for what has been seen; returns it all.
    async fn until(
        &mut self,
        what: &str,
        done: impl Fn(&[SessionEvent]) -> bool,
    ) -> &[SessionEvent] {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            self.drain();
            if done(&self.seen) {
                return &self.seen;
            }
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }
}

fn started_turns(events: &[SessionEvent]) -> Vec<Turn> {
    events
        .iter()
        .filter_map(|e| match e {
            SessionEvent::Delta(TurnDelta::TurnStarted { turn }) => Some(turn.clone()),
            _ => None,
        })
        .collect()
}

fn completed_count(events: &[SessionEvent]) -> usize {
    events
        .iter()
        .filter(|e| matches!(e, SessionEvent::Delta(TurnDelta::TurnCompleted { .. })))
        .count()
}

fn origin_updates(events: &[SessionEvent]) -> Vec<(String, TurnOrigin)> {
    events
        .iter()
        .filter_map(|e| match e {
            SessionEvent::TurnOrigin { turn_id, origin } => Some((turn_id.clone(), origin.clone())),
            _ => None,
        })
        .collect()
}

fn wake_items(origin: &Option<TurnOrigin>) -> Vec<TaskWakeItem> {
    match origin {
        Some(TurnOrigin::TaskWake { items, .. }) => items.clone(),
        other => panic!("expected a task_wake origin, got {other:?}"),
    }
}

// ── stream lines ──────────────────────────────────────────────────────────────

const ASSISTANT_LINE: &str = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#;
const RESULT_LINE: &str = r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}"#;

/// A notification as the CLI writes it.
fn notification(task_id: &str, summary: &str, event_body: &str) -> String {
    format!(
        "<task-notification>\n<task-id>{task_id}</task-id>\n<tool-use-id>toolu_{task_id}</tool-use-id>\n<output-file>/tmp/claude-501/tasks/{task_id}.output</output-file>\n<status>completed</status>\n<summary>{summary}</summary>\n<event>{event_body}</event>\n</task-notification>"
    )
}

/// The user event the CLI emits for `content` (single line, no single quotes).
fn user_line(content: &str) -> String {
    serde_json::json!({"type": "user", "message": {"role": "user", "content": content}}).to_string()
}

fn write_lines(path: &Path, lines: &[String]) {
    let mut text = lines.join("\n");
    text.push('\n');
    std::fs::write(path, text).unwrap();
}

/// Shell: block until `gate` exists.
fn until_exists(gate: &Path) -> String {
    format!("while [ ! -e '{}' ]; do sleep 0.05; done", gate.display())
}

fn a_monitor_wake(task_id: &str) -> String {
    user_line(&notification(
        task_id,
        "Monitor event: &quot;CI for PR&quot;",
        "WAKE-EVENT-BODY",
    ))
}

/// A stub agent: every user frame it reads is echoed as the CLI echoes a
/// prompt, answered and ended with a result.
fn echo_stub() -> String {
    format!(
        r#"while IFS= read -r line; do
  case "$line" in
    *'"type":"user"'*)
      printf '%s\n' "$line"
      printf '%s\n' '{ASSISTANT_LINE}'
      printf '%s\n' '{RESULT_LINE}'
      ;;
  esac
done"#
    )
}

async fn wait_idle(mgr: &SessionManager, tag: &str) {
    eventually("the session to be idle", || {
        (mgr.session_state(tag) == Some(SessionState::Idle)).then_some(())
    })
    .await;
}

// ── 1. the CLI wakes an idle session ──────────────────────────────────────────

#[tokio::test]
async fn a_wake_the_cli_starts_while_idle_is_a_cli_turn_that_keeps_its_wake_origin() {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let wake = dir.path().join("wake.jsonl");
    write_lines(&wake, &[a_monitor_wake("m1")]);
    let go = dir.path().join("go");
    let finish = dir.path().join("finish");
    let script = format!(
        "{}; cat '{}'; printf '%s\\n' '{ASSISTANT_LINE}'; {}; printf '%s\\n' '{RESULT_LINE}'; sleep 30",
        until_exists(&go),
        wake.display(),
        until_exists(&finish),
    );
    spawn_stub(&mut mgr, "w1", &script);
    let heard = record_turns(&mut mgr);
    let mut feed = Feed::of(&mgr, "w1");
    assert_eq!(mgr.session_state("w1"), Some(SessionState::Idle));

    std::fs::write(&go, b"go").unwrap();
    wait_for_events(&heard, "w1", 1).await;

    assert_eq!(
        heard_by(&heard, "w1"),
        vec![TurnEvent::Started {
            author: TurnAuthor::Cli
        }]
    );
    assert_eq!(
        mgr.session_state("w1"),
        Some(SessionState::MidTurn),
        "a wake turn is a turn in progress"
    );
    let turns = started_turns(
        feed.until("TurnStarted", |e| !started_turns(e).is_empty())
            .await,
    );
    assert_eq!(turns.len(), 1);
    let items = wake_items(&turns[0].origin);
    assert_eq!(
        (items[0].kind.as_str(), items[0].outcome.as_str()),
        ("monitor", "new_output")
    );

    std::fs::write(&finish, b"go").unwrap();
    let events = wait_for_events(&heard, "w1", 2).await;
    wait_idle(&mgr, "w1").await;

    assert_eq!(events[1], TurnEvent::Completed);
    mgr.stop("w1");
}

// ── 2. the user's message in flight when the CLI wakes ────────────────────────

#[tokio::test]
async fn a_wake_arriving_before_the_echo_of_the_users_message_stays_the_clis_and_the_users_turn_follows(
) {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let wake = dir.path().join("wake.jsonl");
    write_lines(&wake, &[a_monitor_wake("m1")]);
    let go = dir.path().join("go");
    // The wake and its turn first; only then is the user's line read (it is
    // already in the pipe), echoed and answered.
    let script = format!(
        r#"{wait}
cat '{wake}'
printf '%s\n' '{ASSISTANT_LINE}'
printf '%s\n' '{RESULT_LINE}'
IFS= read -r line
printf '%s\n' "$line"
printf '%s\n' '{ASSISTANT_LINE}'
printf '%s\n' '{RESULT_LINE}'
sleep 30"#,
        wait = until_exists(&go),
        wake = wake.display(),
    );
    spawn_stub(&mut mgr, "w2", &script);
    let heard = record_turns(&mut mgr);
    let mut feed = Feed::of(&mgr, "w2");

    mgr.send_user_message("w2", "my own words", &[]).unwrap();
    std::fs::write(&go, b"go").unwrap();
    let events = wait_for_events(&heard, "w2", 4).await;

    assert_eq!(
        events,
        vec![
            TurnEvent::Started {
                author: TurnAuthor::Cli
            },
            TurnEvent::Completed,
            TurnEvent::Started {
                author: TurnAuthor::User
            },
            TurnEvent::Completed,
        ],
        "the wake is the CLI's even with a user message in flight; the message keeps its own turn"
    );
    let turns = started_turns(
        feed.until("both turns", |e| started_turns(e).len() == 2)
            .await,
    );
    assert!(
        matches!(turns[0].origin, Some(TurnOrigin::TaskWake { .. })),
        "the wake keeps its origin: {:?}",
        turns[0].origin
    );
    assert_eq!(turns[1].origin, None);
    assert!(turns[1].user_input.contains("my own words"));
    mgr.stop("w2");
}

// ── 3. a message that merely looks like a notification ────────────────────────

fn quoted_notification() -> String {
    notification(
        "q1",
        "Monitor event: &quot;pasted&quot;",
        "PASTED-EVENT-BODY",
    )
}

#[tokio::test]
async fn a_user_message_that_starts_with_a_task_notification_is_the_users_turn_with_no_wake_origin()
{
    let mut mgr = SessionManager::with_store_path(tmp_store());
    spawn_stub(&mut mgr, "w3u", &echo_stub());
    let heard = record_turns(&mut mgr);
    let mut feed = Feed::of(&mgr, "w3u");

    mgr.send_user_message("w3u", &quoted_notification(), &[])
        .unwrap();
    let events = wait_for_events(&heard, "w3u", 2).await;

    assert_eq!(
        events[0],
        TurnEvent::Started {
            author: TurnAuthor::User
        },
        "authorship comes from who wrote the message, not from its text"
    );
    let turns = started_turns(
        feed.until("TurnStarted", |e| !started_turns(e).is_empty())
            .await,
    );
    assert_eq!(
        turns[0].origin, None,
        "the wake origin read from the text is taken back before the delta is broadcast"
    );
    assert!(
        turns[0].user_input.starts_with('⟲'),
        "the turn keeps the fallback line: {:?}",
        turns[0].user_input
    );
    assert!(!turns[0].user_input.contains("PASTED-EVENT-BODY"));
    mgr.stop("w3u");
}

#[tokio::test]
async fn an_injected_message_that_starts_with_a_task_notification_is_the_injected_turn_with_no_wake_origin(
) {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    spawn_stub(&mut mgr, "w3i", &echo_stub());
    let heard = record_turns(&mut mgr);
    let mut feed = Feed::of(&mgr, "w3i");
    let key = format!("{SELECTION_KEY_PREFIX}1");

    mgr.inject("w3i", &quoted_notification(), key.clone())
        .unwrap();
    let events = wait_for_events(&heard, "w3i", 2).await;

    match &events[0] {
        TurnEvent::Started {
            author: TurnAuthor::Injected { key: got, .. },
        } => assert_eq!(*got, key),
        other => panic!("the injected message's turn: {other:?}"),
    }
    let turns = started_turns(
        feed.until("TurnStarted", |e| !started_turns(e).is_empty())
            .await,
    );
    assert_eq!(turns[0].origin, None);
    assert!(
        turns[0].user_input.starts_with('⟲'),
        "{:?}",
        turns[0].user_input
    );
    mgr.stop("w3i");
}

// ── 4. a message sent during a wake turn ──────────────────────────────────────

#[tokio::test]
async fn a_message_sent_during_a_wake_turn_waits_and_is_written_after_the_wake_turns_result() {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("stdin.log");
    let wake = dir.path().join("wake.jsonl");
    write_lines(&wake, &[a_monitor_wake("m1")]);
    let go = dir.path().join("go");
    let finish = dir.path().join("finish");
    let script = format!(
        r#"exec 3<&0
cat <&3 >> '{log}' &
{wait_go}
cat '{wake}'
printf '%s\n' '{ASSISTANT_LINE}'
{wait_finish}
printf '%s\n' '{RESULT_LINE}'
sleep 30"#,
        log = log.display(),
        wake = wake.display(),
        wait_go = until_exists(&go),
        wait_finish = until_exists(&finish),
    );
    spawn_stub(&mut mgr, "w4", &script);
    let heard = record_turns(&mut mgr);

    std::fs::write(&go, b"go").unwrap();
    wait_for_events(&heard, "w4", 1).await;
    assert_eq!(mgr.session_state("w4"), Some(SessionState::MidTurn));

    mgr.send_user_message("w4", "after the wake please", &[])
        .unwrap();

    assert_eq!(
        queued(&mgr, "w4"),
        vec!["after the wake please".to_string()],
        "queued, not written, while the wake turn runs"
    );
    assert!(
        !std::fs::read_to_string(&log)
            .unwrap_or_default()
            .contains("after the wake please"),
        "nothing reached the CLI's stdin yet"
    );

    std::fs::write(&finish, b"go").unwrap();
    let written = wait_for_file(&log, "after the wake please").await;

    assert!(written.contains(r#""type":"user""#), "{written}");
    assert!(queued(&mgr, "w4").is_empty());
    let events = wait_for_events(&heard, "w4", 2).await;
    assert_eq!(events[1], TurnEvent::Completed, "the wake turn ended first");
    mgr.stop("w4");
}

// ── 5. two notifications, no reply between ────────────────────────────────────

#[tokio::test]
async fn two_notifications_with_no_reply_between_make_one_turn_and_one_origin_update_with_both_items(
) {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let wake = dir.path().join("wake.jsonl");
    write_lines(
        &wake,
        &[
            a_monitor_wake("first1"),
            user_line(&notification(
                "second2",
                "Background command &quot;make test&quot; failed",
                "SECOND-BODY",
            )),
            ASSISTANT_LINE.to_string(),
            RESULT_LINE.to_string(),
        ],
    );
    let go = dir.path().join("go");
    let script = format!("{}; cat '{}'; sleep 30", until_exists(&go), wake.display());
    spawn_stub(&mut mgr, "w5", &script);
    let mut feed = Feed::of(&mgr, "w5");

    std::fs::write(&go, b"go").unwrap();
    let events = feed
        .until("the wake turn to complete", |e| completed_count(e) >= 1)
        .await
        .to_vec();

    let turns = started_turns(&events);
    assert_eq!(
        turns.len(),
        1,
        "the second notification is no new turn: {events:?}"
    );
    assert_eq!(
        wake_items(&turns[0].origin).len(),
        1,
        "the delta carries the first item"
    );
    let updates = origin_updates(&events);
    assert_eq!(updates.len(), 1, "exactly one origin update: {updates:?}");
    assert_eq!(updates[0].0, turns[0].id);
    let merged = wake_items(&Some(updates[0].1.clone()));
    assert_eq!(
        merged
            .iter()
            .map(|i| i.task_id.as_deref().unwrap_or(""))
            .collect::<Vec<_>>(),
        vec!["first1", "second2"],
        "the full merged origin, in order"
    );
    mgr.stop("w5");
}
