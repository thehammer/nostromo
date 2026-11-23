//! Merged delivery in `step` (`merge.rs`): when typed messages are queued
//! behind a turn, the turn's end writes them as ONE frame; a lone message,
//! a command, an app message and an injected item stay frames of their own.
//!
//! Sessions are stub `sh -c` children whose stdin is recorded (see
//! `turn_note_tests`). No `claude`, no network.

use super::merge::{self, MERGE_MAX_MESSAGES};
use super::queue::AppLabel;
use super::turn_note_tests::{
    contents, eventually, frames_read, note_block, session, turn_runs, wait_for_contents, Offer,
};
use super::*;
use crate::ipc::auth_failure::{AuthSignal, TurnAuthOutcome};
use crate::ipc::protocol::QueueResultCode;
use std::sync::atomic::AtomicUsize;

fn typed(text: &str) -> PendingMessage {
    PendingMessage::typed(text, &[], None)
}

fn queue(shared: &Shared, msgs: Vec<PendingMessage>) -> Vec<String> {
    let ids = msgs.iter().map(|m| m.id.clone()).collect();
    lock_recover(&shared.pending).extend(msgs);
    ids
}

fn idle_session(dir: &tempfile::TempDir) -> (turn_note_tests::Reap, Shared, PathBuf) {
    session(dir, "t", &Arc::new(Offer::default()))
}

fn parts_of(frame: &str) -> Vec<String> {
    merge::parse(frame)
        .unwrap_or_else(|| panic!("not a merged frame: {frame}"))
        .parts
}

fn png(dir: &tempfile::TempDir, name: &str) -> String {
    let path = dir.path().join(name);
    std::fs::write(&path, b"\x89PNG fake").unwrap();
    path.display().to_string()
}

// ── merging ───────────────────────────────────────────────────────────────────

#[tokio::test]
async fn queued_typed_messages_are_written_as_one_frame() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    let ids = queue(&shared, vec![typed("a"), typed("b")]);

    advance(&shared);

    let frames = wait_for_contents(&out, 1).await;
    assert_eq!(frames.len(), 1, "one frame for two messages");
    assert_eq!(parts_of(&frames[0]), ["a", "b"]);
    assert!(frames[0].starts_with("<nostromo-batch count=\"2\""));
    assert!(lock_recover(&shared.pending).is_empty());
    let delivered = shared.queue.delivered_ids();
    assert_eq!(delivered, ids, "every part is in the delivered ring");
}

#[tokio::test]
async fn a_single_queued_message_is_written_byte_identical() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    queue(&shared, vec![typed("just one")]);

    advance(&shared);

    assert_eq!(wait_for_contents(&out, 1).await, ["just one"]);
}

#[tokio::test]
async fn a_slash_command_is_a_boundary_and_stays_its_own_frame() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    queue(&shared, vec![typed("a"), typed("/compact"), typed("b")]);

    for _ in 0..3 {
        advance(&shared);
        turn_runs(&shared);
    }

    assert_eq!(wait_for_contents(&out, 3).await, ["a", "/compact", "b"]);
}

#[tokio::test]
async fn an_app_message_is_a_boundary_and_its_hook_runs_once_on_its_own_delivery() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    let ran = Arc::new(AtomicUsize::new(0));
    let hook = Arc::clone(&ran);
    let mut app = PendingMessage::app("from app", &[], AppLabel::WorkItem);
    app.on_delivered = Some(DeliveredHook(Arc::new(move || {
        hook.fetch_add(1, Ordering::SeqCst);
    })));
    queue(&shared, vec![typed("a"), app, typed("b")]);

    for _ in 0..3 {
        advance(&shared);
        turn_runs(&shared);
    }

    assert_eq!(wait_for_contents(&out, 3).await, ["a", "from app", "b"]);
    assert_eq!(ran.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn an_injected_item_is_a_boundary() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    let mut items = vec![typed("a")];
    items.push(PendingMessage::injected("k".into(), "terminal output"));
    items.push(typed("b"));
    queue(&shared, items);

    for _ in 0..3 {
        advance(&shared);
        turn_runs(&shared);
    }

    let frames = wait_for_contents(&out, 3).await;
    assert_eq!(frames[0], "a");
    assert!(frames[1].contains("terminal output"));
    assert_eq!(frames[2], "b");
}

#[tokio::test]
async fn twenty_one_messages_make_a_batch_of_twenty_then_one() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    queue(
        &shared,
        (0..=MERGE_MAX_MESSAGES)
            .map(|i| typed(&format!("m{i}")))
            .collect(),
    );

    advance(&shared);
    turn_runs(&shared);
    advance(&shared);

    let frames = wait_for_contents(&out, 2).await;
    assert_eq!(parts_of(&frames[0]).len(), MERGE_MAX_MESSAGES);
    assert_eq!(frames[1], format!("m{MERGE_MAX_MESSAGES}"));
}

// ── the gate ──────────────────────────────────────────────────────────────────

#[tokio::test]
async fn with_a_legacy_client_attached_each_message_is_its_own_frame() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    shared.queue.set_legacy_clients(1);
    queue(&shared, vec![typed("a"), typed("b")]);

    advance(&shared);
    turn_runs(&shared);
    advance(&shared);

    assert_eq!(wait_for_contents(&out, 2).await, ["a", "b"]);
}

#[tokio::test]
async fn the_gate_follows_attach_detach_and_disconnect() {
    let dir = tempfile::tempdir().unwrap();
    let (mut reap, shared, _out) = idle_session(&dir);
    let mgr = &mut reap.0;
    mgr.set_client_merge_capable("new", true);
    mgr.attach("t", "new").unwrap();
    assert!(
        shared.queue.merge_allowed(),
        "a capable client keeps merging"
    );
    mgr.attach("t", "old").unwrap();
    assert!(
        !shared.queue.merge_allowed(),
        "a legacy client closes the gate"
    );
    mgr.on_client_disconnect("old");
    assert!(
        shared.queue.merge_allowed(),
        "its socket dropping without a detach reopens it"
    );
    mgr.attach("t", "old2").unwrap();
    assert!(!shared.queue.merge_allowed());
    mgr.detach("t", "old2");
    assert!(shared.queue.merge_allowed());
}

#[tokio::test]
async fn the_view_groups_the_entries_that_will_merge() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, _out) = idle_session(&dir);
    let items = vec![
        typed("a"),
        typed("b"),
        typed("/clear"),
        PendingMessage::app("x", &[], AppLabel::WorkItem),
        typed("c"),
        typed("d"),
        typed("e"),
    ];
    queue(&shared, items);
    let groups = |s: &Shared| -> Vec<Option<u32>> {
        s.queue_view()
            .current()
            .entries
            .iter()
            .map(|e| e.merge_group)
            .collect()
    };

    assert_eq!(
        groups(&shared),
        [Some(1), Some(1), None, None, Some(2), Some(2), Some(2)]
    );
    shared.queue.set_legacy_clients(1);
    assert!(groups(&shared).iter().all(Option::is_none));
}

// ── notes ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_merged_frame_carries_one_note_block_in_front_of_the_header_and_commits_once() {
    let dir = tempfile::tempdir().unwrap();
    let offer = Offer::owing("tracker note");
    let (_reap, shared, out) = session(&dir, "t", &offer);
    *shared.note_prefix.lock().unwrap() = Some("model note".into());
    queue(&shared, vec![typed("a"), typed("b"), typed("c")]);

    advance(&shared);
    assert_eq!(offer.committed(), 0, "not by the write alone");
    turn_runs(&shared);

    let frames = wait_for_contents(&out, 1).await;
    assert_eq!(frames[0].matches(NOSTROMO_NOTE_OPEN).count(), 1);
    assert!(frames[0].starts_with(&note_block("model note\n\ntracker note", "<nostromo-batch")));
    assert_eq!(
        parts_of(crate::ipc::stream_json::strip_nostromo_note(&frames[0])),
        ["a", "b", "c"]
    );
    assert_eq!(offer.committed(), 1, "one commit for the whole batch");
}

// ── images ────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn images_merge_into_one_array_frame_each_after_its_own_section() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    let (i1, i2, i3) = (png(&dir, "1.png"), png(&dir, "2.png"), png(&dir, "3.png"));
    queue(
        &shared,
        vec![
            PendingMessage::typed("a", &[i1], None),
            PendingMessage::typed("b", &[i2, i3], None),
        ],
    );

    advance(&shared);

    let frames = eventually("a frame", || {
        Some(frames_read(&out)).filter(|f| !f.is_empty())
    })
    .await;
    assert_eq!(frames.len(), 1);
    let blocks = frames[0]["message"]["content"].as_array().unwrap();
    let kinds: Vec<&str> = blocks.iter().map(|b| b["type"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["text", "image", "text", "image", "image"]);
    let joined = blocks
        .iter()
        .filter_map(|b| b["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    assert_eq!(parts_of(&joined), ["a", "b"]);
    assert!(blocks[0]["text"]
        .as_str()
        .unwrap()
        .starts_with("<nostromo-batch"));
}

#[tokio::test]
async fn an_unreadable_image_note_sits_after_its_own_sections_end_marker() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    let good = png(&dir, "ok.png");
    queue(
        &shared,
        vec![
            PendingMessage::typed("a", &["/nonexistent/gone.png".to_owned()], None),
            PendingMessage::typed("b", &[good], None),
        ],
    );

    advance(&shared);

    let frames = eventually("a frame", || {
        Some(frames_read(&out)).filter(|f| !f.is_empty())
    })
    .await;
    let blocks = frames[0]["message"]["content"].as_array().unwrap();
    let first = blocks[0]["text"].as_str().unwrap();
    let end = first.find("<<<END-MESSAGE-").unwrap();
    let note = first.find("could not read the attached image").unwrap();
    assert!(note > end, "the note follows the END marker: {first}");
    let joined = blocks
        .iter()
        .filter_map(|b| b["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    assert_eq!(parts_of(&joined), ["a", "b"]);
}

// ── atomic ────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_failed_write_puts_every_part_back_in_order_with_the_same_ids_and_the_next_turn_merges_them(
) {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    let ids = queue(&shared, vec![typed("a"), typed("b"), typed("c")]);
    let stdin = lock_recover(&shared.stdin).take();

    advance(&shared);

    let back: Vec<(String, String)> = lock_recover(&shared.pending)
        .iter()
        .map(|m| (m.id.clone(), m.text.clone()))
        .collect();
    assert_eq!(
        back,
        ids.iter()
            .cloned()
            .zip(["a", "b", "c"].map(String::from))
            .collect::<Vec<_>>(),
        "all three, in order, individually, with their ids"
    );
    assert!(shared.queue.delivered_ids().is_empty());
    *lock_recover(&shared.stdin) = stdin;

    advance(&shared);

    let frames = wait_for_contents(&out, 1).await;
    assert_eq!(parts_of(&frames[0]), ["a", "b", "c"]);
}

#[tokio::test]
async fn a_take_back_racing_an_in_flight_batch_answers_already_delivered_for_every_part() {
    let dir = tempfile::tempdir().unwrap();
    let (reap, shared, _out) = idle_session(&dir);
    let ids = queue(&shared, vec![typed("a"), typed("b")]);
    advance(&shared);

    for id in &ids {
        let answer = reap.0.queue_verb("t", id, QueueVerb::TakeBack);
        assert_eq!(answer.code, QueueResultCode::AlreadyDelivered, "{id}");
    }
}

#[tokio::test]
async fn taking_back_the_newest_of_three_then_resending_it_merges_it_at_the_end() {
    let dir = tempfile::tempdir().unwrap();
    let (reap, shared, out) = idle_session(&dir);
    let ids = queue(&shared, vec![typed("a"), typed("b"), typed("c")]);
    let answer = reap.0.queue_verb("t", &ids[2], QueueVerb::TakeBack);
    assert_eq!(answer.text.as_deref(), Some("c"));
    queue(&shared, vec![typed("c")]);

    advance(&shared);

    assert_eq!(
        parts_of(&wait_for_contents(&out, 1).await[0]),
        ["a", "b", "c"]
    );
}

// ── provenance ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn the_batch_ledger_records_the_boundary_and_count_and_never_the_text() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, out) = idle_session(&dir);
    queue(&shared, vec![typed("CANARY-ONE"), typed("CANARY-TWO")]);

    advance(&shared);

    let frame = wait_for_contents(&out, 1).await.remove(0);
    let boundary = merge::parse(&frame).unwrap().boundary;
    let hub = &shared.ctx.hub;
    let records = crate::model::batches::load(&hub.paths.batches_dir, &shared.ctx.session_id);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].boundary, boundary);
    assert_eq!(records[0].count, 2);
    let raw = std::fs::read_to_string(crate::model::batches::ledger_path(
        &hub.paths.batches_dir,
        &shared.ctx.session_id,
    ))
    .unwrap();
    assert!(
        !raw.contains("CANARY"),
        "no message text in the ledger: {raw}"
    );
    assert!(contents(&out)[0].contains("CANARY-ONE"));
}

#[tokio::test]
async fn a_bound_batch_exposes_its_parts_to_the_reader() {
    let dir = tempfile::tempdir().unwrap();
    let (_reap, shared, _out) = idle_session(&dir);
    queue(&shared, vec![typed("a"), typed("b")]);
    advance(&shared);
    assert_eq!(login::bound_batch_parts(&shared), None, "not bound yet");

    login::on_turn_started(&shared);

    assert_eq!(
        login::bound_batch_parts(&shared),
        Some(vec!["a".to_owned(), "b".to_owned()])
    );
}

// ── the held batch ────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_held_batch_is_one_entry_whose_take_back_returns_all_texts_and_images() {
    let dir = tempfile::tempdir().unwrap();
    let (reap, shared, out) = idle_session(&dir);
    let (i1, i2) = (png(&dir, "1.png"), png(&dir, "2.png"));
    let ids = queue(
        &shared,
        vec![
            PendingMessage::typed("one", std::slice::from_ref(&i1), None),
            PendingMessage::typed("two", std::slice::from_ref(&i2), None),
        ],
    );
    advance(&shared);
    eventually("the batch frame", || {
        (!frames_read(&out).is_empty()).then_some(())
    })
    .await;
    login::on_turn_started(&shared);
    // The turn fails to authenticate: the frame is held.
    login::on_turn_end(
        &shared,
        "t",
        Some(TurnAuthOutcome {
            signal: AuthSignal::ErrorField,
            resendable: true,
        }),
    );

    let held = shared.login.held_entry().expect("held");
    assert_eq!(
        held.id, ids[0],
        "the held batch is one entry, the first part's id"
    );
    let answer = reap.0.queue_verb("t", &held.id, QueueVerb::TakeBack);
    assert_eq!(answer.code, QueueResultCode::TakenBack);
    assert_eq!(answer.text.as_deref(), Some("one\n\ntwo"));
    assert_eq!(answer.images, [i1, i2]);
    assert!(shared.login.held_entry().is_none());
    assert_eq!(contents_len(&out), 1, "nothing is resent");
}

fn ledger_records(shared: &Shared) -> Vec<crate::model::batches::BatchRecord> {
    crate::model::batches::load(&shared.ctx.hub.paths.batches_dir, &shared.ctx.session_id)
}

fn fail_sign_in(shared: &Shared) {
    login::on_turn_started(shared);
    login::on_turn_end(
        shared,
        "t",
        Some(TurnAuthOutcome {
            signal: AuthSignal::ErrorField,
            resendable: true,
        }),
    );
}

#[tokio::test]
async fn every_write_of_a_merged_frame_gets_exactly_one_ledger_record_resends_included() {
    let dir = tempfile::tempdir().unwrap();
    let (mut reap, shared, out) = idle_session(&dir);
    queue(&shared, vec![typed("one"), typed("two")]);
    advance(&shared);
    eventually("the batch frame", || {
        (!frames_read(&out).is_empty()).then_some(())
    })
    .await;
    assert_eq!(
        ledger_records(&shared).len(),
        1,
        "the first write: one record"
    );

    for resend in 1..=2usize {
        fail_sign_in(&shared);
        // The failed turn ends with the session idle again, as it does live.
        *lock_recover(&shared.state) = SessionState::Idle;
        let held = shared.login.held_entry().expect("held");
        let outcome = reap
            .0
            .resend_held("t", &held.hold_id, login::ResendTrigger::Manual);
        assert_eq!(outcome, login::ResendOutcome::Resent);
        assert_eq!(
            wait_for_contents(&out, 1 + resend).await.len(),
            1 + resend,
            "written again"
        );
        let records = ledger_records(&shared);
        assert_eq!(records.len(), 1 + resend, "one record per physical write");
        assert!(records
            .iter()
            .all(|r| r.boundary == records[0].boundary && r.count == 2));
    }
}

/// A session whose merged frame of `one` and `two` failed to authenticate and
/// is held, with `three` and `four` queued behind it.
async fn held_batch_with_two_waiting(
    dir: &tempfile::TempDir,
) -> (turn_note_tests::Reap, Shared, PathBuf, Vec<String>) {
    let (reap, shared, out) = idle_session(dir);
    let mut ids = queue(&shared, vec![typed("one"), typed("two")]);
    advance(&shared);
    eventually("the batch frame", || {
        (!frames_read(&out).is_empty()).then_some(())
    })
    .await;
    login::on_turn_started(&shared);
    login::on_turn_end(
        &shared,
        "t",
        Some(TurnAuthOutcome {
            signal: AuthSignal::ErrorField,
            resendable: true,
        }),
    );
    assert!(shared.login.held_entry().is_some(), "held");
    ids.extend(queue(&shared, vec![typed("three"), typed("four")]));
    (reap, shared, out, ids)
}

#[tokio::test]
async fn removing_a_held_batch_discards_every_part_and_resends_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let (reap, shared, out, _ids) = held_batch_with_two_waiting(&dir).await;
    lock_recover(&shared.pending).clear();
    let held = shared.login.held_entry().expect("held");

    let answer = reap.0.queue_verb("t", &held.id, QueueVerb::Remove);

    assert_eq!(answer.code, QueueResultCode::Removed);
    assert!(shared.login.held_entry().is_none());
    advance(&shared);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(contents_len(&out), 1, "no part is resent");
    assert!(
        lock_recover(&shared.pending).is_empty(),
        "no part re-queued"
    );
}

#[tokio::test]
async fn stop_with_a_held_batch_returns_its_parts_then_the_queued_messages_separately() {
    let dir = tempfile::tempdir().unwrap();
    let (mut reap, _shared, _out, ids) = held_batch_with_two_waiting(&dir).await;

    let (_, dropped) = reap.0.interrupt_returning("t");

    let got: Vec<(&str, &str)> = dropped
        .typed
        .iter()
        .map(|e| (e.id.as_str(), e.text.as_str()))
        .collect();
    let want: Vec<(&str, &str)> = ids
        .iter()
        .map(String::as_str)
        .zip(["one", "two", "three", "four"])
        .collect();
    assert_eq!(got, want, "each message separately, original ids, in order");
    assert_eq!(dropped.ids, ids);
}

#[tokio::test]
async fn stopping_the_whole_session_returns_the_held_parts_first() {
    let dir = tempfile::tempdir().unwrap();
    let (reap, shared, _out, ids) = held_batch_with_two_waiting(&dir).await;

    let lost = reap.0.discard_queue_for_session_stop("t");

    assert_eq!(lost, ids, "held one and two, then three and four");
    assert!(shared.login.held_entry().is_none());
    assert!(lock_recover(&shared.pending).is_empty());
}

fn contents_len(out: &Path) -> usize {
    frames_read(out).len()
}
