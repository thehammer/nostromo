//! The store on its own: retention, what reaches the file, the degraded
//! backup, and the privacy purges. Temp dirs only; all text is invented.

use super::*;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
const NOW: i64 = 1_800_000_000_000;

fn open(dir: &Path) -> ConversationHistory {
    ConversationHistory::open(dir.join("conversation-history.json"))
}

fn file(dir: &Path) -> String {
    std::fs::read_to_string(dir.join("conversation-history.json")).unwrap_or_default()
}

fn spawn(h: &ConversationHistory, sid: &str, tag: &str, at: i64) {
    h.note_spawn(
        SpawnNote {
            tag,
            sid,
            agent: "cody",
            cwd: None,
            title: "A title",
            label: None,
            model: None,
        },
        at,
    );
}

/// A conversation with its first message answered.
fn visible(h: &ConversationHistory, sid: &str, text: &str, at: i64) {
    h.note_user_send(sid, text, false, false, at);
    h.turn_completed(sid, true, false, at);
}

// ── retention ─────────────────────────────────────────────────────────────────

#[test]
fn entries_idle_for_more_than_90_days_are_dropped_on_write_and_newer_ones_kept() {
    let h = ConversationHistory::in_memory();
    for (sid, age) in [
        ("old", 91 * DAY_MS),
        ("just-over", MAX_AGE_MS + 1),
        ("just-under", MAX_AGE_MS - 60_000),
        ("recent", 10 * DAY_MS),
    ] {
        spawn(&h, sid, "cody-1", NOW - age);
        visible(&h, sid, "hello", NOW - age);
    }
    // Any change applies retention.
    h.set_first_prompts_enabled(true, NOW);
    let kept: Vec<String> = h.snapshot().entries.into_iter().map(|e| e.sid).collect();
    assert!(!kept.contains(&"old".to_owned()), "{kept:?}");
    assert!(!kept.contains(&"just-over".to_owned()), "{kept:?}");
    assert!(kept.contains(&"just-under".to_owned()), "{kept:?}");
    assert!(kept.contains(&"recent".to_owned()), "{kept:?}");
}

#[test]
fn only_the_500_most_recently_active_visible_entries_are_kept() {
    let h = ConversationHistory::in_memory();
    for i in 0..505 {
        let sid = format!("sid-{i}");
        let at = NOW - 3_600_000 + i as i64;
        spawn(&h, &sid, "cody-1", at);
        visible(&h, &sid, "hello", at);
    }
    h.set_first_prompts_enabled(true, NOW);
    let snap = h.snapshot();
    assert_eq!(snap.entries.len(), 500);
    // The five oldest went; the newest stayed.
    for i in 0..5 {
        assert!(
            h.get(&format!("sid-{i}")).is_none(),
            "sid-{i} should be gone"
        );
    }
    assert!(h.get("sid-504").is_some());
    assert!(h.get("sid-5").is_some());
}

// ── what reaches the file ─────────────────────────────────────────────────────

#[test]
fn a_queued_a_discarded_and_a_delivered_first_message_reach_the_history_differently() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    for (sid, tag) in [
        ("s-queued", "t1"),
        ("s-discarded", "t2"),
        ("s-delivered", "t3"),
    ] {
        spawn(&h, sid, tag, NOW);
    }
    // Queued: written, then its turn failed to sign in (held), and the
    // conversation's next message queued behind it. Neither is ever a prompt.
    h.note_user_send("s-queued", "QUEUEDMARK first", false, false, NOW);
    h.turn_completed("s-queued", false, false, NOW);
    h.note_user_send("s-queued", "BEHINDMARK second", false, false, NOW);
    assert!(
        h.snapshot().entries.iter().all(|e| e.sid != "s-queued"),
        "a held message makes nothing visible"
    );
    // Discarded: the user stopped the held message.
    h.note_user_send("s-discarded", "DISCARDMARK", false, false, NOW);
    h.discard_candidate("s-discarded");
    h.turn_completed("s-discarded", true, false, NOW);
    // Delivered.
    h.note_user_send(
        "s-delivered",
        "DELIVEREDMARK fix the picker",
        false,
        false,
        NOW,
    );
    assert!(
        h.snapshot().entries.is_empty(),
        "a message only written is not yet a conversation"
    );
    h.turn_completed("s-delivered", true, false, NOW);

    h.flush();
    let on_disk = file(dir.path());
    assert!(!on_disk.contains("QUEUEDMARK"), "{on_disk}");
    assert!(!on_disk.contains("BEHINDMARK"), "{on_disk}");
    assert!(!on_disk.contains("DISCARDMARK"), "{on_disk}");
    assert!(
        on_disk.contains("DELIVEREDMARK fix the picker"),
        "{on_disk}"
    );
    let delivered = h.get("s-delivered").unwrap();
    assert!(delivered.has_turn);

    // The held conversation shows once its turn is delivered, with no prompt;
    // the discarded one never shows.
    h.turn_completed("s-queued", true, false, NOW);
    let queued = h.get("s-queued").unwrap();
    assert!(queued.has_turn);
    assert_eq!(queued.first_prompt, FirstPrompt::None);
    assert!(!h.get("s-discarded").unwrap().has_turn);
    h.flush();
    let on_disk = file(dir.path());
    assert!(!on_disk.contains("QUEUEDMARK") && !on_disk.contains("BEHINDMARK"));
}

#[test]
fn a_sensitive_message_stores_only_the_fixed_marker_when_it_is_delivered() {
    let h = ConversationHistory::in_memory();
    spawn(&h, "s1", "teri", NOW);
    h.note_user_send("s1", "SENSITIVEMARK", false, true, NOW);
    h.turn_completed("s1", true, true, NOW);
    let e = h.get("s1").unwrap();
    assert_eq!(
        e.first_prompt,
        FirstPrompt::Withheld(Reason::SensitiveConversation)
    );
}

#[test]
fn turning_first_prompts_off_purges_every_stored_prompt_from_the_file_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    spawn(&h, "s1", "t1", NOW);
    visible(&h, "s1", "PROMPTMARK one", NOW);
    spawn(&h, "s2", "t2", NOW);
    visible(&h, "s2", "PROMPTMARK two", NOW);
    assert!(file(dir.path()).contains("PROMPTMARK one"));
    h.set_first_prompts_enabled(false, NOW + 1);
    // No flush: the purge is on disk the moment the setting changes.
    let on_disk = file(dir.path());
    assert!(!on_disk.contains("PROMPTMARK"), "{on_disk}");
    assert!(on_disk.contains("\"off\""));
    assert_eq!(
        h.get("s1").unwrap().first_prompt,
        FirstPrompt::Withheld(Reason::Off)
    );
    // And a candidate waiting for its delivery is gone too.
    spawn(&h, "s3", "t3", NOW);
    h.note_user_send("s3", "LATEMARK", false, false, NOW);
    h.set_first_prompts_enabled(false, NOW + 2);
    h.turn_completed("s3", true, false, NOW + 3);
    assert!(!file(dir.path()).contains("LATEMARK"));
}

#[test]
fn a_tag_that_becomes_sensitive_loses_its_prompt_and_branch_with_no_further_send() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    spawn(&h, "s1", "cody-1", NOW);
    visible(&h, "s1", "TOPSECRETMARK plan", NOW);
    h.apply_tail(
        "s1",
        Path::new("/t/s1.jsonl"),
        10,
        Some("BRANCHMARK".into()),
        &[3],
        NOW,
    );
    h.flush();
    assert!(file(dir.path()).contains("BRANCHMARK"));
    assert!(file(dir.path()).contains("TOPSECRETMARK"));

    h.sweep_sensitive(|tag, _| tag == "cody-1", NOW + 1);
    let on_disk = file(dir.path());
    assert!(!on_disk.contains("TOPSECRETMARK"), "{on_disk}");
    assert!(!on_disk.contains("BRANCHMARK"), "{on_disk}");
    let e = h.get("s1").unwrap();
    assert!(e.sensitive);
    assert_eq!(
        e.first_prompt,
        FirstPrompt::Withheld(Reason::SensitiveConversation)
    );

    // The branch stops updating.
    h.apply_tail(
        "s1",
        Path::new("/t/s1.jsonl"),
        20,
        Some("NEWBRANCHMARK".into()),
        &[],
        NOW + 2,
    );
    h.flush();
    assert!(h.get("s1").unwrap().branch.is_none());
    assert!(!file(dir.path()).contains("NEWBRANCHMARK"));
}

#[test]
fn a_completed_turn_of_a_now_sensitive_focus_purges_without_a_send() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    spawn(&h, "s1", "cody-1", NOW);
    visible(&h, "s1", "COMPLETEDMARK hello", NOW);
    h.apply_tail(
        "s1",
        Path::new("/t/s1.jsonl"),
        10,
        Some("DONEBRANCH".into()),
        &[],
        NOW,
    );
    h.turn_completed("s1", true, true, NOW + 1);
    let on_disk = file(dir.path());
    assert!(
        !on_disk.contains("COMPLETEDMARK") && !on_disk.contains("DONEBRANCH"),
        "{on_disk}"
    );
}

// ── the degraded history and its backup ───────────────────────────────────────

#[test]
fn an_unreadable_file_is_kept_as_a_backup_and_nothing_is_written_while_degraded() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("conversation-history.json");
    std::fs::write(&path, "this is {not json").unwrap();
    let h = ConversationHistory::open(path.clone());
    assert!(h.counts().2, "degraded");
    assert_eq!(
        std::fs::read(dir.path().join("conversation-history.json.bak")).unwrap(),
        b"this is {not json"
    );
    spawn(&h, "s1", "t1", NOW);
    visible(&h, "s1", "WHILEDEGRADED", NOW);
    h.set_first_prompts_enabled(true, NOW);
    h.flush();
    assert_eq!(
        std::fs::read(&path).unwrap(),
        b"this is {not json",
        "the unreadable file is left exactly as it was"
    );
    assert_eq!(h.snapshot().degraded_kept, Some(0));
}

#[test]
fn the_backup_kept_while_degraded_loses_its_prompts_when_prompts_are_turned_off() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("conversation-history.json");
    // Valid JSON, but not a history this build can read (entries lack fields).
    let body =
        r#"{"entries":[{"sid":"s1","first_prompt":{"kind":"text","value":"OLDPROMPTMARK"}}]}"#;
    std::fs::write(&path, body).unwrap();
    let h = ConversationHistory::open(path.clone());
    assert!(h.counts().2);
    let bak = dir.path().join("conversation-history.json.bak");
    assert!(std::fs::read_to_string(&bak)
        .unwrap()
        .contains("OLDPROMPTMARK"));
    h.set_first_prompts_enabled(false, NOW);
    let after = std::fs::read_to_string(&bak).unwrap_or_default();
    assert!(!after.contains("OLDPROMPTMARK"), "{after}");
    assert!(
        after.contains("s1"),
        "the rest of the backup is kept: {after}"
    );
}

#[test]
fn a_backup_that_is_not_json_is_removed_when_prompts_are_turned_off() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("conversation-history.json");
    std::fs::write(
        &path,
        "{\"first_prompt\":{\"kind\":\"text\",\"value\":\"RAWMARK\"",
    )
    .unwrap();
    let h = ConversationHistory::open(path);
    h.set_first_prompts_enabled(false, NOW);
    assert!(!dir.path().join("conversation-history.json.bak").exists());
}

// ── the debounced write ───────────────────────────────────────────────────────

#[test]
fn ordinary_activity_is_written_after_the_debounce_not_on_every_send() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    spawn(&h, "s1", "t1", NOW);
    visible(&h, "s1", "hello", NOW);
    let first = file(dir.path());
    assert!(first.contains("hello"), "a first prompt is written at once");
    for i in 1..=5 {
        h.note_user_send("s1", "later", false, false, NOW + i * 1000);
    }
    assert_eq!(
        file(dir.path()),
        first,
        "later sends only bump a time: no rewrite of the whole file each time"
    );
    h.flush();
    assert_ne!(
        file(dir.path()),
        first,
        "the pending change is written on flush"
    );
    // An atomic write: no temp file is left behind.
    let leftovers: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
        .collect();
    assert!(leftovers.is_empty());
}

#[test]
fn a_privacy_change_is_written_even_while_an_ordinary_one_is_pending() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    spawn(&h, "s1", "t1", NOW);
    visible(&h, "s1", "PENDINGMARK", NOW);
    h.note_user_send("s1", "x", false, false, NOW + 1);
    h.sweep_sensitive(|_, _| true, NOW + 2);
    assert!(!file(dir.path()).contains("PENDINGMARK"));
}

// ── resume bookkeeping survives a restart ─────────────────────────────────────

#[test]
fn a_pending_resume_is_kept_in_the_file_until_the_first_turn_succeeds() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    spawn(&h, "s1", "cody-old", NOW);
    visible(&h, "s1", "hello", NOW);
    h.move_to_tag("s1", "cody-new", NOW + 1);
    assert_eq!(
        h.pending_resume_for_tag("cody-new"),
        Some(("s1".into(), "cody-old".into()))
    );
    // A daemon restart before the first send loses nothing.
    let again = open(dir.path());
    assert_eq!(
        again.pending_resume_for_tag("cody-new"),
        Some(("s1".into(), "cody-old".into()))
    );
    // A turn that failed to sign in is not a success.
    again.turn_completed("s1", false, false, NOW + 2);
    assert!(again.pending_resume_for_tag("cody-new").is_some());
    again.turn_completed("s1", true, false, NOW + 3);
    assert!(again.pending_resume_for_tag("cody-new").is_none());
    assert!(open(dir.path())
        .pending_resume_for_tag("cody-new")
        .is_none());
}
