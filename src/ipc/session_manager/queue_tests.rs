//! The message queue's identity, view, take-back and remove, through a real
//! `SessionManager` and stub `sh` children (`docs/message-queue.md`).
//!
//! Contract under test:
//!
//! * every typed message has a stable id from send time, kind `typed`/`app`,
//!   and daemon-injected items never appear in the view;
//! * take-back and remove are decided by the daemon, once, behind any
//!   in-flight write: `taken_back`/`removed` for a queued typed entry,
//!   `already_delivered` for a delivered one, `not_found` for anything else,
//!   `not_allowed` for an app entry;
//! * a message that leaves by take-back, remove or Stop never runs its
//!   delivered hook;
//! * Stop hands back the typed entries it dropped, held first;
//! * a restart carries the queue (ids and order) and watchers keep hearing it;
//! * a user stop tells watchers `session_stopped` with the typed ids lost;
//! * the race test: delivered, taken back, removed or dropped by Stop,
//!   exactly one of them, for every typed message, and the answer matches.

use super::*;
use crate::ipc::protocol::{QueueChangeReason, QueueEntryKindWire, QueueResultCode};
use std::sync::atomic::AtomicUsize;

fn tmp_store() -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!("nostromo-queue-test-{}.json", Uuid::new_v4()));
    p
}

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

/// A session whose turn is running (no message of ours started it), so every
/// send queues. The child records what it reads on stdin into `out`.
fn busy(tag: &str, out: &Path) -> SessionManager {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    spawn_stub(&mut mgr, tag, &format!("cat >> '{}'", out.display()));
    *lock_recover(&mgr.sessions[tag].shared.state) = SessionState::MidTurn;
    mgr
}

fn shared_of(mgr: &SessionManager, tag: &str) -> Shared {
    mgr.sessions[tag].shared.clone()
}

/// The user-message texts the child has read so far.
fn written(out: &Path) -> Vec<String> {
    std::fs::read_to_string(out)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .filter(|f| f["type"] == "user")
        .filter_map(|f| f["message"]["content"].as_str().map(str::to_owned))
        .collect()
}

fn wait_for(what: &str, mut ok: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ok() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// A turn ends: the next queued message is written.
fn turn_ends(mgr: &SessionManager, tag: &str) {
    advance(&mgr.sessions[tag].shared);
}

fn texts(snap: &QueueSnapshot) -> Vec<String> {
    snap.entries.iter().map(|e| e.text.clone()).collect()
}

// ── identity and view ─────────────────────────────────────────────────────────

#[tokio::test]
async fn the_view_lists_typed_and_app_entries_in_order_and_never_the_injected_ones() {
    let dir = tempfile::tempdir().unwrap();
    let mut mgr = busy("t", &dir.path().join("in"));
    let a = mgr
        .send_typed_message("t", "first", &[], Some("ref-1".into()))
        .unwrap();
    mgr.send_app_message("t", "from the app", &[], AppLabel::WorkItem)
        .unwrap();
    mgr.inject("t", "terminal output", "term-1".into()).unwrap();
    mgr.send_typed_message("t", "/compact now", &["/tmp/a.png".into()], None)
        .unwrap();

    let snap = shared_of(&mgr, "t").queue_view().current();

    assert_eq!(
        texts(&snap),
        ["first", "from the app", "/compact now"],
        "oldest first, injected left out"
    );
    let first = &snap.entries[0];
    assert_eq!(first.id, a);
    assert_eq!(first.kind, QueueEntryKindWire::Typed);
    assert_eq!(first.client_ref.as_deref(), Some("ref-1"));
    assert!(first.can_take_back && !first.command && first.image_count == 0);
    let app = &snap.entries[1];
    assert_eq!(app.kind, QueueEntryKindWire::App);
    assert_eq!(app.app_label.as_deref(), Some("work_item"));
    assert!(!app.can_take_back);
    let command = &snap.entries[2];
    assert!(command.command && command.image_count == 1);
    assert!(snap.held.is_none());
}

#[tokio::test]
async fn a_client_ref_that_is_not_printable_ascii_or_too_long_is_ignored_not_refused() {
    let dir = tempfile::tempdir().unwrap();
    let mut mgr = busy("t", &dir.path().join("in"));
    for bad in [
        "é-not-ascii".to_string(),
        "x".repeat(65),
        "tab\there".into(),
    ] {
        mgr.send_typed_message("t", "m", &[], Some(bad))
            .expect("the message is accepted");
    }
    mgr.send_typed_message("t", "ok", &[], Some("x".repeat(64)))
        .unwrap();
    let snap = shared_of(&mgr, "t").queue_view().current();
    assert!(snap.entries[..3].iter().all(|e| e.client_ref.is_none()));
    assert_eq!(
        snap.entries[3].client_ref.as_deref(),
        Some("x".repeat(64).as_str())
    );
}

#[tokio::test]
async fn a_typed_message_written_at_once_has_an_id_and_is_remembered_as_delivered() {
    let dir = tempfile::tempdir().unwrap();
    let mut mgr = SessionManager::with_store_path(tmp_store());
    spawn_stub(
        &mut mgr,
        "t",
        &format!("cat >> '{}'", dir.path().join("in").display()),
    );
    let id = mgr.send_typed_message("t", "now", &[], None).unwrap();
    assert!(shared_of(&mgr, "t").queue.delivered_ids().contains(&id));
    let answer = mgr.queue_verb("t", &id, QueueVerb::TakeBack);
    assert_eq!(answer.code, QueueResultCode::AlreadyDelivered);
    assert!(answer.text.is_none());
}

// ── take back and remove ──────────────────────────────────────────────────────

#[tokio::test]
async fn take_back_returns_the_exact_text_and_images_and_the_child_never_gets_it() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("in");
    let mut mgr = busy("t", &out);
    let images = vec!["/tmp/one.png".to_string(), "/tmp/two.png".to_string()];
    let a = mgr
        .send_typed_message("t", "take me back", &images, None)
        .unwrap();
    mgr.send_typed_message("t", "stay", &[], None).unwrap();

    let answer = mgr.queue_verb("t", &a, QueueVerb::TakeBack);

    assert_eq!(answer.code, QueueResultCode::TakenBack);
    assert_eq!(answer.text.as_deref(), Some("take me back"));
    assert_eq!(answer.images, images);
    assert_eq!(
        texts(&shared_of(&mgr, "t").queue_view().current()),
        ["stay"]
    );
    turn_ends(&mgr, "t");
    wait_for("the next message", || written(&out) == ["stay"]);
    assert_eq!(
        written(&out),
        ["stay"],
        "the taken-back message is never written"
    );
}

#[tokio::test]
async fn remove_answers_removed_without_text_and_a_repeat_is_not_found() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("in");
    let mut mgr = busy("t", &out);
    let a = mgr.send_typed_message("t", "drop me", &[], None).unwrap();
    let b = mgr.send_typed_message("t", "and me", &[], None).unwrap();

    let removed = mgr.queue_verb("t", &a, QueueVerb::Remove);
    assert_eq!(removed.code, QueueResultCode::Removed);
    assert!(removed.text.is_none() && removed.images.is_empty());
    assert_eq!(
        mgr.queue_verb("t", &a, QueueVerb::Remove).code,
        QueueResultCode::NotFound
    );
    assert_eq!(
        mgr.queue_verb("t", &a, QueueVerb::TakeBack).code,
        QueueResultCode::NotFound
    );
    assert_eq!(
        mgr.queue_verb("t", &b, QueueVerb::TakeBack).code,
        QueueResultCode::TakenBack
    );
    assert_eq!(
        mgr.queue_verb("t", &b, QueueVerb::TakeBack).code,
        QueueResultCode::NotFound
    );
    assert_eq!(
        mgr.queue_verb("t", "q-never-issued", QueueVerb::Remove)
            .code,
        QueueResultCode::NotFound
    );
    assert_eq!(
        mgr.queue_verb("nope", &a, QueueVerb::Remove).code,
        QueueResultCode::NotFound
    );
    turn_ends(&mgr, "t");
    std::thread::sleep(Duration::from_millis(100));
    assert!(written(&out).is_empty());
}

#[tokio::test]
async fn a_delivered_entry_answers_already_delivered() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("in");
    let mut mgr = busy("t", &out);
    let a = mgr.send_typed_message("t", "go", &[], None).unwrap();
    turn_ends(&mgr, "t");
    wait_for("delivery", || written(&out) == ["go"]);
    assert_eq!(
        mgr.queue_verb("t", &a, QueueVerb::TakeBack).code,
        QueueResultCode::AlreadyDelivered
    );
    assert_eq!(
        mgr.queue_verb("t", &a, QueueVerb::Remove).code,
        QueueResultCode::AlreadyDelivered
    );
}

#[tokio::test]
async fn app_entries_are_not_allowed_stay_queued_and_are_delivered_with_their_hook_once() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("in");
    let mut mgr = busy("t", &out);
    let told = Arc::new(AtomicUsize::new(0));
    let hook = Arc::clone(&told);
    mgr.send_app_message_then("t", "Tell notify", AppLabel::MotherOverview, move || {
        hook.fetch_add(1, Ordering::SeqCst);
    })
    .unwrap();
    mgr.send_app_message("t", "work item", &[], AppLabel::WorkItem)
        .unwrap();
    mgr.send_app_message("t", "seed", &[], AppLabel::AgentSeed)
        .unwrap();
    let ids: Vec<String> = shared_of(&mgr, "t")
        .queue_view()
        .current()
        .entries
        .iter()
        .map(|e| e.id.clone())
        .collect();
    assert_eq!(ids.len(), 3);

    for id in &ids {
        for verb in [QueueVerb::TakeBack, QueueVerb::Remove] {
            let answer = mgr.queue_verb("t", id, verb);
            assert_eq!(answer.code, QueueResultCode::NotAllowed);
            assert!(answer.text.is_none());
        }
    }
    assert_eq!(told.load(Ordering::SeqCst), 0, "not told before delivery");
    for _ in 0..3 {
        turn_ends(&mgr, "t");
    }
    wait_for("all three", || written(&out).len() == 3);
    assert_eq!(written(&out), ["Tell notify", "work item", "seed"]);
    assert_eq!(
        told.load(Ordering::SeqCst),
        1,
        "the hook runs once, on delivery"
    );
}

#[tokio::test]
async fn a_message_taken_back_removed_or_dropped_by_stop_never_runs_its_hook() {
    let dir = tempfile::tempdir().unwrap();
    let mut mgr = busy("t", &dir.path().join("in"));
    let ran = Arc::new(AtomicUsize::new(0));
    let mut ids = Vec::new();
    for text in ["a", "b", "c"] {
        let hook = Arc::clone(&ran);
        mgr.send_user_message_then("t", text, move || {
            hook.fetch_add(1, Ordering::SeqCst);
        })
        .unwrap();
    }
    for e in shared_of(&mgr, "t").queue_view().current().entries {
        ids.push(e.id);
    }
    assert_eq!(
        mgr.queue_verb("t", &ids[0], QueueVerb::TakeBack).code,
        QueueResultCode::TakenBack
    );
    assert_eq!(
        mgr.queue_verb("t", &ids[1], QueueVerb::Remove).code,
        QueueResultCode::Removed
    );
    let (_, dropped) = mgr.interrupt_returning("t");
    assert_eq!(dropped.typed.len(), 1);
    turn_ends(&mgr, "t");
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(ran.load(Ordering::SeqCst), 0);
}

// ── Stop ──────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn stop_returns_the_typed_entries_in_order_with_text_and_images_and_writes_none() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("in");
    let mut mgr = busy("t", &out);
    let a = mgr
        .send_typed_message("t", "one", &["/tmp/i.png".into()], None)
        .unwrap();
    mgr.send_app_message("t", "app", &[], AppLabel::WorkItem)
        .unwrap();
    mgr.inject("t", "injected", "k".into()).unwrap();
    let b = mgr.send_typed_message("t", "two", &[], None).unwrap();

    let (outcome, dropped) = mgr.interrupt_returning("t");

    assert!(outcome.is_ok());
    let got: Vec<(String, String, Vec<String>)> = dropped
        .typed
        .iter()
        .map(|e| (e.id.clone(), e.text.clone(), e.images.clone()))
        .collect();
    assert_eq!(
        got,
        [
            (a.clone(), "one".to_string(), vec!["/tmp/i.png".to_string()]),
            (b.clone(), "two".to_string(), vec![]),
        ]
    );
    assert!(lock_recover(&mgr.sessions["t"].shared.pending).is_empty());
    assert_eq!(
        mgr.queue_verb("t", &a, QueueVerb::TakeBack).code,
        QueueResultCode::NotFound
    );
    turn_ends(&mgr, "t");
    std::thread::sleep(Duration::from_millis(100));
    assert!(written(&out)
        .iter()
        .all(|t| t != "one" && t != "two" && t != "app"));
}

// ── watchers ──────────────────────────────────────────────────────────────────

fn register_client(mgr: &SessionManager, id: &str) -> mpsc::UnboundedReceiver<ServerMsg> {
    let (tx, rx) = mpsc::unbounded_channel();
    mgr.client_senders.lock().unwrap().insert(id.into(), tx);
    rx
}

/// The queue frames received so far as (rev, change reason, entry texts).
fn queue_frames(rx: &mut mpsc::UnboundedReceiver<ServerMsg>) -> Vec<QueueSnapshot> {
    let mut out = Vec::new();
    while let Ok(msg) = rx.try_recv() {
        if let ServerMsg::SessionQueue {
            rev,
            entries,
            held,
            change,
            ..
        } = msg
        {
            out.push(QueueSnapshot {
                rev,
                entries,
                held,
                change,
            });
        }
    }
    out
}

async fn queue_frames_after(
    rx: &mut mpsc::UnboundedReceiver<ServerMsg>,
    mut enough: impl FnMut(&[QueueSnapshot]) -> bool,
) -> Vec<QueueSnapshot> {
    let mut all = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        all.extend(queue_frames(rx));
        if enough(&all) {
            return all;
        }
        assert!(Instant::now() < deadline, "timed out; got {all:?}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

#[tokio::test]
async fn a_watcher_gets_the_snapshot_at_once_and_one_per_change_and_a_bystander_none() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("in");
    let mut mgr = busy("t", &out);
    let mut watcher = register_client(&mgr, "w");
    let mut bystander = register_client(&mgr, "b");
    mgr.attach("t", "b").unwrap();
    mgr.attach("t", "w").unwrap();
    let a = mgr.send_typed_message("t", "a", &[], None).unwrap();
    mgr.queue_watch("t", "w").unwrap();

    let first = queue_frames_after(&mut watcher, |f| !f.is_empty()).await;
    assert_eq!(texts(&first[0]), ["a"], "the current snapshot at once");

    let b = mgr.send_typed_message("t", "b", &[], None).unwrap();
    let frames = queue_frames_after(&mut watcher, |f| !f.is_empty()).await;
    assert_eq!(
        frames[0].change.as_ref().unwrap().reason,
        QueueChangeReason::Queued
    );
    assert_eq!(
        frames[0].change.as_ref().unwrap().ids,
        std::slice::from_ref(&b)
    );
    assert_eq!(texts(&frames[0]), ["a", "b"]);

    mgr.queue_verb("t", &a, QueueVerb::TakeBack);
    let frames = queue_frames_after(&mut watcher, |f| !f.is_empty()).await;
    assert_eq!(
        frames[0].change.as_ref().unwrap().reason,
        QueueChangeReason::TakenBack
    );
    assert_eq!(texts(&frames[0]), ["b"]);

    turn_ends(&mgr, "t");
    let frames = queue_frames_after(&mut watcher, |f| !f.is_empty()).await;
    assert_eq!(
        frames[0].change.as_ref().unwrap().reason,
        QueueChangeReason::Delivered
    );
    assert!(frames[0].entries.is_empty());

    // Revisions only go up.
    let mut revs = vec![first[0].rev];
    revs.extend(frames.iter().map(|f| f.rev));
    assert!(revs.windows(2).all(|w| w[0] < w[1]), "{revs:?}");

    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(
        queue_frames(&mut bystander).is_empty(),
        "a connection that never watched sees no queue frame"
    );
}

#[tokio::test]
async fn stop_publishes_a_stopped_snapshot_to_every_watcher() {
    let dir = tempfile::tempdir().unwrap();
    let mut mgr = busy("t", &dir.path().join("in"));
    let mut watcher = register_client(&mgr, "w");
    mgr.attach("t", "w").unwrap();
    let a = mgr.send_typed_message("t", "a", &[], None).unwrap();
    mgr.queue_watch("t", "w").unwrap();
    queue_frames_after(&mut watcher, |f| !f.is_empty()).await;

    let _ = mgr.interrupt_returning("t");

    let frames = queue_frames_after(&mut watcher, |f| !f.is_empty()).await;
    let change = frames.last().unwrap().change.clone().unwrap();
    assert_eq!(change.reason, QueueChangeReason::Stopped);
    assert_eq!(change.ids, [a]);
    assert!(frames.last().unwrap().entries.is_empty());
}

#[tokio::test]
async fn a_restart_carries_the_queue_with_the_same_ids_and_watchers_keep_hearing_it() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("in");
    let mut mgr = busy("t", &out);
    let mut watcher = register_client(&mgr, "w");
    mgr.attach("t", "w").unwrap();
    let a = mgr.send_typed_message("t", "a", &[], None).unwrap();
    let b = mgr.send_typed_message("t", "b", &[], None).unwrap();
    mgr.queue_watch("t", "w").unwrap();
    queue_frames_after(&mut watcher, |f| !f.is_empty()).await;

    mgr.restart("t").unwrap();

    // The first carried message went to the new process; the rest are queued.
    let frames = queue_frames_after(&mut watcher, |f| {
        f.iter().any(|s| {
            !s.entries.is_empty()
                || s.change
                    .as_ref()
                    .is_some_and(|c| c.reason == QueueChangeReason::Delivered)
        })
    })
    .await;
    let last = frames.last().unwrap();
    let ids: Vec<&str> = last.entries.iter().map(|e| e.id.as_str()).collect();
    assert!(
        ids == [b.as_str()] || ids.is_empty() || ids == [a.as_str(), b.as_str()],
        "same ids, same order: {ids:?}"
    );
    // The watch was never re-sent, yet a later change still arrives.
    let c = mgr.send_typed_message("t", "c", &[], None).unwrap();
    let frames = queue_frames_after(&mut watcher, |f| {
        f.iter().any(|s| s.entries.iter().any(|e| e.id == c))
    })
    .await;
    assert!(frames.last().unwrap().entries.iter().any(|e| e.id == c));
    // The carried ids answer the verbs after the restart.
    let answer = mgr.queue_verb("t", &b, QueueVerb::TakeBack);
    assert!(
        matches!(
            answer.code,
            QueueResultCode::TakenBack | QueueResultCode::AlreadyDelivered
        ),
        "{answer:?}"
    );
}

#[tokio::test]
async fn a_user_stop_tells_the_watchers_session_stopped_with_the_typed_ids_lost() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("in");
    let mut mgr = busy("t", &out);
    let mut watcher = register_client(&mgr, "w");
    let mut other = register_client(&mgr, "o");
    mgr.attach("t", "w").unwrap();
    mgr.attach("t", "o").unwrap();
    let a = mgr.send_typed_message("t", "a", &[], None).unwrap();
    mgr.send_app_message("t", "app", &[], AppLabel::WorkItem)
        .unwrap();
    let b = mgr.send_typed_message("t", "b", &[], None).unwrap();
    mgr.queue_watch("t", "w").unwrap();
    queue_frames_after(&mut watcher, |f| !f.is_empty()).await;

    mgr.stop("t");

    let frames = queue_frames_after(&mut watcher, |f| !f.is_empty()).await;
    let last = frames.last().unwrap();
    let change = last.change.clone().unwrap();
    assert_eq!(change.reason, QueueChangeReason::SessionStopped);
    assert_eq!(change.ids, [a, b], "the typed ids, in order");
    assert!(last.entries.is_empty() && last.held.is_none());
    assert!(
        queue_frames(&mut other).is_empty(),
        "a connection that never watched hears nothing"
    );
    turn_ends(&mgr, "t");
    std::thread::sleep(Duration::from_millis(100));
    assert!(written(&out).is_empty(), "nothing lost is ever written");
}

#[tokio::test]
async fn a_lagging_watcher_is_sent_the_current_snapshot() {
    let dir = tempfile::tempdir().unwrap();
    let mut mgr = busy("t", &dir.path().join("in"));
    let mut watcher = register_client(&mgr, "w");
    mgr.attach("t", "w").unwrap();
    mgr.queue_watch("t", "w").unwrap();
    queue_frames_after(&mut watcher, |f| !f.is_empty()).await;
    // Far more events than the channel holds, before the forwarder runs.
    let shared = shared_of(&mgr, "t");
    for _ in 0..5000 {
        shared.broadcast(SessionEvent::State(SessionState::MidTurn));
    }
    mgr.send_typed_message("t", "last", &[], None).unwrap();
    let frames = queue_frames_after(&mut watcher, |f| {
        f.last().is_some_and(|s| texts(s) == ["last"])
    })
    .await;
    assert_eq!(texts(frames.last().unwrap()), ["last"]);
}

// ── the race ──────────────────────────────────────────────────────────────────

/// A small deterministic generator (xorshift64*), so a seed replays the same plan.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    fn micros(&mut self, max: u64) -> Duration {
        Duration::from_micros(self.below(max))
    }
}

#[derive(Default)]
struct Answers {
    taken_back: u32,
    removed: u32,
    already_delivered: u32,
    not_found: u32,
}

/// One interleaving. Returns what it found wrong (empty when all is well).
fn run_interleaving(seed: u64, skip_wait: bool) -> Vec<String> {
    const MESSAGES: usize = 4;
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("in");
    let mut mgr = busy("t", &out);
    let texts: Vec<String> = (0..MESSAGES).map(|i| format!("m{seed}-{i}")).collect();
    let ids: Vec<String> = texts
        .iter()
        .map(|t| mgr.send_typed_message("t", t, &[], None).unwrap())
        .collect();
    let shared = shared_of(&mgr, "t");
    let mgr = Mutex::new(mgr);
    let answers: Mutex<HashMap<String, Answers>> = Mutex::new(HashMap::new());
    let stop_dropped: Mutex<Vec<String>> = Mutex::new(Vec::new());
    let mut rng = Rng::new(seed);
    // One plan per thread, drawn up front so a seed is a plan.
    let drains: Vec<(Duration, Duration)> = (0..1 + rng.below(4))
        .map(|_| (rng.micros(600), rng.micros(300)))
        .collect();
    let in_flight_pause_us = 50 + rng.below(350);
    let fail_at = rng.micros(600);
    let fail_for = rng.micros(500);
    let fails = rng.below(2) == 0;
    let stop_at = rng.micros(900);
    let stops = rng.below(2) == 0;
    let takers: Vec<(Duration, QueueVerb, Option<Duration>)> = (0..MESSAGES)
        .map(|_| {
            let verb = if rng.below(2) == 0 {
                QueueVerb::TakeBack
            } else {
                QueueVerb::Remove
            };
            let again = (rng.below(3) == 0).then(|| rng.micros(700));
            (rng.micros(900), verb, again)
        })
        .collect();

    std::thread::scope(|scope| {
        scope.spawn(|| {
            queue::IN_FLIGHT_PAUSE_US.with(|c| c.set(in_flight_pause_us));
            for (wait, gap) in &drains {
                std::thread::sleep(*wait);
                advance(&shared);
                std::thread::sleep(*gap);
            }
        });
        if fails {
            scope.spawn(|| {
                std::thread::sleep(fail_at);
                let taken = lock_recover(&shared.stdin).take();
                std::thread::sleep(fail_for);
                *lock_recover(&shared.stdin) = taken;
            });
        }
        if stops {
            scope.spawn(|| {
                std::thread::sleep(stop_at);
                let (_, dropped) = lock_recover(&mgr).interrupt_returning("t");
                lock_recover(&stop_dropped).extend(dropped.ids);
            });
        }
        for (i, (at, verb, again)) in takers.iter().enumerate() {
            let (mgr, answers, id) = (&mgr, &answers, &ids[i]);
            scope.spawn(move || {
                queue::SKIP_WRITE_WAIT.with(|c| c.set(skip_wait));
                for delay in std::iter::once(*at).chain(*again) {
                    std::thread::sleep(delay);
                    let answer = lock_recover(mgr).queue_verb("t", id, *verb);
                    let mut all = lock_recover(answers);
                    let entry = all.entry(id.clone()).or_default();
                    match answer.code {
                        QueueResultCode::TakenBack => entry.taken_back += 1,
                        QueueResultCode::Removed => entry.removed += 1,
                        QueueResultCode::AlreadyDelivered => entry.already_delivered += 1,
                        QueueResultCode::NotFound => entry.not_found += 1,
                        QueueResultCode::NotAllowed => panic!("a typed entry is allowed"),
                    }
                }
            });
        }
    });

    // Quiesce: whatever is still queued is delivered by further turn ends.
    let mut guard = 0;
    while !lock_recover(&shared.pending).is_empty() {
        advance(&shared);
        guard += 1;
        assert!(guard < 50, "seed {seed}: the queue never drained");
    }
    while shared.writing.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(1));
    }
    let claimed = shared.queue.delivered_ids();
    wait_for("the child to read what was delivered", || {
        written(&out).len() >= claimed.len()
    });
    std::thread::sleep(Duration::from_millis(3));

    let frames = written(&out);
    let dropped = lock_recover(&stop_dropped).clone();
    let answers = lock_recover(&answers);
    let mut problems = Vec::new();
    for (i, id) in ids.iter().enumerate() {
        let text = &texts[i];
        let times = frames.iter().filter(|f| *f == text).count();
        let a = answers.get(id);
        let (taken, removed, already, not_found) = a.map_or((0, 0, 0, 0), |a| {
            (a.taken_back, a.removed, a.already_delivered, a.not_found)
        });
        let delivered = times == 1;
        let was_dropped = dropped.contains(id);
        let outcomes = u32::from(delivered) + taken + removed + u32::from(was_dropped);
        if times > 1 {
            problems.push(format!("seed {seed}: {id} written {times} times"));
        }
        if outcomes != 1 {
            problems.push(format!(
                "seed {seed}: {id} has {outcomes} outcomes (delivered {delivered}, taken {taken}, \
                 removed {removed}, dropped {was_dropped})"
            ));
        }
        if already > 0 && !delivered {
            problems.push(format!(
                "seed {seed}: {id} answered already_delivered but never was"
            ));
        }
        if not_found > 0 && delivered {
            problems.push(format!(
                "seed {seed}: {id} answered not_found but was delivered"
            ));
        }
        if claimed.contains(id) != delivered {
            problems.push(format!(
                "seed {seed}: {id} delivered ring and child disagree"
            ));
        }
    }
    drop(answers);
    lock_recover(&mgr).stop_session("t");
    problems
}

const RACE_SEEDS: u64 = 1000;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_typed_message_is_delivered_taken_back_removed_or_dropped_exactly_once() {
    println!("queue race: seeds 1..={RACE_SEEDS}");
    let problems = tokio::task::spawn_blocking(|| {
        (1..=RACE_SEEDS)
            .flat_map(|seed| run_interleaving(seed, false))
            .collect::<Vec<_>>()
    })
    .await
    .unwrap();
    assert!(problems.is_empty(), "{problems:#?}");
}

/// The mutation that proves the race test: deciding without waiting for the
/// in-flight write must be caught.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_race_test_catches_a_decision_made_without_waiting_for_the_in_flight_write() {
    let caught = tokio::task::spawn_blocking(|| {
        (1..=RACE_SEEDS)
            .filter(|seed| !run_interleaving(*seed, true).is_empty())
            .count()
    })
    .await
    .unwrap();
    println!("queue race mutation: caught in {caught} of {RACE_SEEDS} seeds (1..={RACE_SEEDS})");
    assert!(
        caught > 0,
        "the mutation went unnoticed in {RACE_SEEDS} interleavings"
    );
}

/// After the wait limit passes with a write stuck, only the id being written
/// answers `already_delivered`; an unknown id is still `not_found`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stuck_write_makes_only_its_own_id_already_delivered_others_stay_not_found() {
    let dir = tempfile::tempdir().unwrap();
    let mut mgr = busy("t", &dir.path().join("in"));
    let writing_id = mgr.send_typed_message("t", "stuck", &[], None).unwrap();
    let removed = mgr.send_typed_message("t", "gone", &[], None).unwrap();
    assert_eq!(
        mgr.queue_verb("t", &removed, QueueVerb::Remove).code,
        QueueResultCode::Removed
    );
    // A write of `writing_id` that never finishes (the limit is five seconds).
    let shared = shared_of(&mgr, "t");
    lock_recover(&shared.pending).retain(|m| m.id != writing_id);
    *lock_recover(&shared.writing_ids) = vec![writing_id.clone()];
    shared.writing.store(true, Ordering::SeqCst);

    let answers = tokio::task::spawn_blocking(move || {
        [
            mgr.queue_verb("t", &writing_id, QueueVerb::TakeBack).code,
            mgr.queue_verb("t", "q-never-issued", QueueVerb::Remove)
                .code,
            mgr.queue_verb("t", &removed, QueueVerb::TakeBack).code,
        ]
    })
    .await
    .unwrap();
    assert_eq!(
        answers,
        [
            QueueResultCode::AlreadyDelivered,
            QueueResultCode::NotFound,
            QueueResultCode::NotFound
        ]
    );
}
