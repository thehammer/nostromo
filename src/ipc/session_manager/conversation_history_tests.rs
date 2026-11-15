//! The conversation history through a real `SessionManager` and a stub `claude`
//! that records its argv and stdin. Temp dirs only; all text is invented.

use super::tests::CLAUDE_BIN_ENV_LOCK;
use super::*;
use crate::conversations::list;
use crate::conversations::transcript::PROJECTS_DIR_ENV;
use crate::conversations::{ConversationHistory, FirstPrompt, Reason};
use crate::ipc::protocol::ConversationResumeOutcome;
use crate::model::store::{FocusModelRecord, ModelSource};
use std::sync::MutexGuard;

/// Holds the process-wide env lock; points the stub CLI and the projects
/// folder at the temp dir; undoes both on drop.
struct Rig {
    _lock: MutexGuard<'static, ()>,
    dir: tempfile::TempDir,
    mgr: SessionManager,
    cwd: PathBuf,
}

impl Drop for Rig {
    fn drop(&mut self) {
        // A stub still reading its stdin would hold the manager's drop forever.
        let tags: Vec<String> = self.mgr.sessions.keys().cloned().collect();
        for tag in tags {
            self.mgr.stop_session(&tag);
        }
        std::env::remove_var(CLAUDE_BIN_ENV);
        std::env::remove_var(PROJECTS_DIR_ENV);
    }
}

impl Rig {
    fn new() -> Self {
        use std::os::unix::fs::PermissionsExt;
        let lock = CLAUDE_BIN_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("claude-stub");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\necho \"$@\" >> '{argv}'\ncat >> '{stdin}'\n",
                argv = dir.path().join("argv.log").display(),
                stdin = dir.path().join("stdin.log").display(),
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::env::set_var(CLAUDE_BIN_ENV, &script);
        std::env::set_var(PROJECTS_DIR_ENV, dir.path().join("projects"));
        let cwd = dir.path().join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        let mgr = SessionManager::with_store_path(dir.path().join("daemon-sessions.json"));
        Self {
            _lock: lock,
            dir,
            mgr,
            cwd,
        }
    }

    fn spawn(&mut self, tag: &str, agent: &str) -> String {
        self.mgr
            .spawn_session(
                tag.into(),
                agent.into(),
                "View".into(),
                Some(self.cwd.clone()),
                None,
                false,
            )
            .unwrap()
            .expect("a session id")
    }

    /// A message sent and answered: the turn completed with it delivered.
    fn send(&mut self, tag: &str, text: &str) {
        self.mgr.send_user_message(tag, text, &[]).unwrap();
        self.deliver(tag);
    }

    /// A turn completes in `tag`'s session, its message delivered.
    fn deliver(&self, tag: &str) {
        conversation_history::turn_completed(&self.mgr.sessions[tag].shared, true);
    }

    fn argv_lines(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.path().join("argv.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// Wait until the stub has logged `n` spawns.
    async fn wait_spawns(&self, n: usize) -> Vec<String> {
        injected_tests::eventually("the stub's argv", || {
            let l = self.argv_lines();
            (l.len() >= n).then_some(l)
        })
        .await
    }

    /// A transcript file for `sid` under the fake projects folder.
    fn transcript(&self, sid: &str, body: &str) -> PathBuf {
        let folder =
            self.dir
                .path()
                .join("projects")
                .join(crate::conversations::transcript::encode_cwd(
                    &self.cwd.to_string_lossy(),
                ));
        std::fs::create_dir_all(&folder).unwrap();
        let path = folder.join(format!("{sid}.jsonl"));
        std::fs::write(&path, body).unwrap();
        path
    }

    fn open_in_registry(&mut self, tag: &str) {
        let mut meta = test_focus(tag);
        meta.agent_name = "cody".into();
        self.mgr.set_focus_registry(vec![meta]);
    }
}

fn test_focus(tag: &str) -> FocusMeta {
    FocusMeta {
        tag: tag.into(),
        display_name: format!("Focus {tag}"),
        agent_name: "cody".into(),
        project_name: None,
        org: None,
        is_built_in: false,
        session_summary: None,
        label: None,
        project_path: None,
        select_for_client: None,
        initial_model: None,
        initial_effort: None,
    }
}

const USER_LINE: &str = r#"{"type":"user","message":{"content":"hello there"}}"#;

fn outcome(msg: &ServerMsg) -> (ConversationResumeOutcome, Option<String>, Option<String>) {
    match msg {
        ServerMsg::ConversationResumeResult {
            outcome,
            tag,
            reason,
            ..
        } => (*outcome, tag.clone(), reason.clone()),
        other => panic!("not a resume result: {other:?}"),
    }
}

// ── the store, through the manager ────────────────────────────────────────────

#[tokio::test]
async fn a_spawn_alone_is_hidden_and_the_first_send_makes_the_entry_visible() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    assert!(
        rig.mgr.conversations().snapshot().entries.is_empty(),
        "spawn alone must not list a conversation"
    );
    rig.mgr
        .send_user_message("cody-aaaa1111", "Fix the picker\nsecond line", &[])
        .unwrap();
    assert!(
        rig.mgr.conversations().snapshot().entries.is_empty(),
        "a message only written is not yet a conversation"
    );
    rig.deliver("cody-aaaa1111");
    let snap = rig.mgr.conversations().snapshot();
    assert_eq!(snap.entries.len(), 1);
    assert_eq!(snap.entries[0].sid, sid);
    assert_eq!(
        snap.entries[0].first_prompt,
        FirstPrompt::Text("Fix the picker".into())
    );
}

#[tokio::test]
async fn the_entry_survives_new_session_and_a_daemon_restart() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.mgr.new_session("cody-aaaa1111");
    assert!(rig.mgr.conversations().get(&sid).is_some());
    let reopened = ConversationHistory::open(ConversationHistory::path_beside(
        &rig.dir.path().join("daemon-sessions.json"),
    ));
    assert_eq!(reopened.snapshot().entries.len(), 1);
}

#[tokio::test]
async fn a_restricted_tag_never_creates_an_entry() {
    let mut rig = Rig::new();
    rig.mgr
        .restrict_tag("picks-x", crate::data::work::picks::picks_restrictions());
    let sid = rig.spawn("picks-x", "cody");
    rig.send("picks-x", "UNIQUEPICKSWORD");
    assert!(rig.mgr.conversations().get(&sid).is_none());
}

#[tokio::test]
async fn a_sensitive_agent_stores_no_first_prompt_and_no_branch() {
    let mut rig = Rig::new();
    let sid = rig.spawn("teri", "teri");
    rig.send("teri", "plan my week");
    let e = rig.mgr.conversations().get(&sid).unwrap();
    assert!(e.sensitive);
    assert_eq!(
        e.first_prompt,
        FirstPrompt::Withheld(Reason::SensitiveConversation)
    );
    let listing = list::build(
        &rig.mgr.conversations().snapshot(),
        &rig.mgr.conversations(),
        &HashMap::new(),
    );
    let w = &listing.entries[0];
    assert!(w.branch.is_none() && w.project_path.is_none() && w.project_name.is_none());
    assert!(w.first_prompt.is_none() && w.pr_numbers.is_empty() && w.transcript_path.is_none());
}

#[tokio::test]
async fn a_flagged_first_prompt_text_appears_nowhere_in_the_file() {
    let mut rig = Rig::new();
    rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "SSN was 219-09-9999 ok");
    let file = std::fs::read_to_string(ConversationHistory::path_beside(
        &rig.dir.path().join("daemon-sessions.json"),
    ))
    .unwrap();
    assert!(!file.contains("219-09-9999"), "{file}");
    assert!(file.contains("looked_sensitive"));
}

#[cfg(unix)]
#[tokio::test]
async fn the_history_file_is_private() {
    use std::os::unix::fs::PermissionsExt;
    let mut rig = Rig::new();
    rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    let path = ConversationHistory::path_beside(&rig.dir.path().join("daemon-sessions.json"));
    assert_eq!(
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
        0o600
    );
}

// ── resume ────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn resuming_a_conversation_running_in_an_open_focus_switches_and_starts_nothing() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.open_in_registry("cody-aaaa1111");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    let spawns = rig.wait_spawns(1).await.len();
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(
        outcome(&reply),
        (
            ConversationResumeOutcome::Switch,
            Some("cody-aaaa1111".into()),
            None
        )
    );
    assert_eq!(rig.argv_lines().len(), spawns, "no process was started");
}

#[tokio::test]
async fn a_removed_focus_with_a_live_child_is_stopped_then_resumed_once() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.wait_spawns(1).await;
    // Not in the registry: its focus was removed, the child lives on.
    assert!(rig.mgr.has_live_session("cody-aaaa1111"));
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    assert!(
        !rig.mgr.has_live_session("cody-aaaa1111"),
        "the old child is stopped: never two processes on one conversation"
    );
    // The Mac then creates the focus; its normal spawn picks up the stored id.
    let again = rig.spawn("cody-bbbb2222", "cody");
    assert_eq!(again, sid);
    let lines = rig.wait_spawns(2).await;
    assert!(
        lines[1].contains(&format!("--resume {sid}")),
        "{}",
        lines[1]
    );
    assert_eq!(lines.len(), 2);
    // The conversation now belongs to the new tag, and origin verification follows.
    assert_eq!(
        rig.mgr.conversations().get(&sid).unwrap().tag,
        "cody-bbbb2222"
    );
    assert_eq!(
        rig.mgr.session_history().tag_of(&sid).as_deref(),
        Some("cody-bbbb2222")
    );
    assert!(rig.mgr.session_history().contains("cody-aaaa1111", &sid));
}

#[tokio::test]
async fn releasing_a_cancelled_resume_gives_the_tag_and_the_entry_back() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    let first = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&first).0, ConversationResumeOutcome::Ready);
    rig.mgr.release_resumed_tag("cody-bbbb2222");
    assert!(
        !load_id_store(&rig.mgr.store_path).contains_key("cody-bbbb2222"),
        "no orphan tag -> session id entry"
    );
    assert_eq!(
        rig.mgr.conversations().get(&sid).unwrap().tag,
        "cody-aaaa1111",
        "the entry is back with its previous owner"
    );
    // The reservation is gone: a later resume gets a fresh tag, not a switch.
    let again = rig.mgr.resume_conversation(&sid, "cody-cccc3333");
    assert_eq!(
        outcome(&again),
        (
            ConversationResumeOutcome::Ready,
            Some("cody-cccc3333".into()),
            None
        )
    );
}

#[tokio::test]
async fn releasing_a_tag_whose_focus_is_open_changes_nothing() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    rig.open_in_registry("cody-bbbb2222");
    rig.mgr.release_resumed_tag("cody-bbbb2222");
    assert_eq!(
        load_id_store(&rig.mgr.store_path)
            .get("cody-bbbb2222")
            .map(String::as_str),
        Some(sid.as_str())
    );
    assert_eq!(
        rig.mgr.conversations().get(&sid).unwrap().tag,
        "cody-bbbb2222"
    );
}

#[tokio::test]
async fn a_second_resume_of_the_same_conversation_switches_to_the_first_tag() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    let first = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&first).0, ConversationResumeOutcome::Ready);
    let second = rig.mgr.resume_conversation(&sid, "cody-cccc3333");
    assert_eq!(
        outcome(&second),
        (
            ConversationResumeOutcome::Switch,
            Some("cody-bbbb2222".into()),
            None
        )
    );
}

#[tokio::test]
async fn a_resumed_session_sends_nothing_and_keeps_the_recorded_model() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    model_store::update_focus_record(
        &rig.mgr.model_hub.paths.focus_models,
        "cody-aaaa1111",
        |_| {
            Some(FocusModelRecord {
                model: "opus".into(),
                effort: Some("high".into()),
                source: ModelSource::Focus,
                ..FocusModelRecord::default()
            })
        },
    )
    .unwrap();
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    let before = std::fs::read_to_string(rig.dir.path().join("stdin.log")).unwrap_or_default();
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    let record =
        model_store::focus_record(&rig.mgr.model_hub.paths.focus_models, "cody-bbbb2222").unwrap();
    assert_eq!(
        (record.model.as_str(), record.effort.as_deref()),
        ("opus", Some("high"))
    );
    assert_eq!(record.source, ModelSource::Focus);
    rig.spawn("cody-bbbb2222", "cody");
    rig.wait_spawns(2).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let after = std::fs::read_to_string(rig.dir.path().join("stdin.log")).unwrap_or_default();
    assert_eq!(before, after, "nothing is written to a resumed session");
}

#[tokio::test]
async fn a_resumed_spawn_has_a_fresh_spawns_arguments_apart_from_the_id_flag() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    // Stopping right after the spawn can kill the stub before it logs its argv.
    rig.wait_spawns(1).await;
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    rig.spawn("cody-bbbb2222", "cody");
    let fresh_sid = rig.spawn("cody-cccc3333", "cody");
    let lines = rig.wait_spawns(3).await;
    let strip = |line: &str, sid: &str| -> Vec<String> {
        let words: Vec<&str> = line.split_whitespace().collect();
        let mut out = Vec::new();
        let mut i = 0;
        while i < words.len() {
            if (words[i] == "--resume" || words[i] == "--session-id")
                && words.get(i + 1) == Some(&sid)
            {
                i += 2;
            } else {
                out.push(words[i].replace(sid, "SID"));
                i += 1;
            }
        }
        out
    };
    // Lines 1 (first spawn) and 3 (fresh) are `--session-id`; line 2 is the resume.
    assert!(lines[1].contains("--resume"));
    assert_eq!(
        strip(&lines[1], &sid),
        strip(&lines[2], &fresh_sid)
            .iter()
            .map(|w| w.replace("cody-cccc3333", "cody-bbbb2222"))
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn a_history_write_inside_the_debounce_window_survives_a_clean_shutdown() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    let path = rig.dir.path().join("conversation-history.json");
    let before = std::fs::read_to_string(&path).unwrap();
    // Only a time moves: debounced, so not on disk yet.
    rig.mgr.conversations().note_user_send(
        &sid,
        "later",
        false,
        false,
        crate::conversations::now_ms() + 60_000,
    );
    assert_eq!(std::fs::read_to_string(&path).unwrap(), before);
    rig.mgr
        .kill_all_on_shutdown_with_grace(std::time::Duration::from_millis(500));
    assert_ne!(
        std::fs::read_to_string(&path).unwrap(),
        before,
        "the pending write was flushed by the shutdown"
    );
}

#[tokio::test]
async fn unavailable_and_missing_conversations_are_refused() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    // No transcript was written and a scan has said so.
    rig.mgr.conversations().note_not_found(&sid);
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&reply).2.as_deref(), Some("unavailable"));
    let reply = rig.mgr.resume_conversation("no-such-sid", "cody-bbbb2222");
    assert_eq!(outcome(&reply).2.as_deref(), Some("not_found"));
}

#[tokio::test]
async fn a_conversation_whose_folder_is_gone_is_refused() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    std::fs::remove_dir_all(&rig.cwd).unwrap();
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&reply).2.as_deref(), Some("folder_gone"));
}

#[tokio::test]
async fn a_stale_id_on_a_resumed_tag_never_restarts_fresh() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    // An operator connection to hear about it.
    let (tx, mut rx) = mpsc::unbounded_channel();
    rig.mgr
        .client_senders
        .lock()
        .unwrap()
        .insert("op".into(), tx);
    rig.mgr.mark_operator_conn("op");
    rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    rig.spawn("cody-bbbb2222", "cody");
    rig.wait_spawns(2).await;

    // Claude says it has no such conversation.
    rig.mgr
        .sessions
        .get("cody-bbbb2222")
        .unwrap()
        .stale_session_id
        .store(true, Ordering::SeqCst);
    rig.mgr
        .sessions
        .get_mut("cody-bbbb2222")
        .unwrap()
        .attached_clients
        .insert("c1".into());
    rig.mgr.stop_session("cody-bbbb2222");
    injected_tests::eventually("the child to exit", || {
        (!rig.mgr.sessions["cody-bbbb2222"].alive()).then_some(())
    })
    .await;
    // The exit counts as a crash, not as our own stop.
    rig.mgr.sessions["cody-bbbb2222"]
        .intentional_stop
        .store(false, Ordering::SeqCst);
    rig.mgr.reap_and_recover();

    assert_eq!(rig.argv_lines().len(), 2, "no fresh restart was started");
    assert!(
        !load_id_store(&rig.mgr.store_path).contains_key("cody-bbbb2222"),
        "the failed tag keeps no stored id: a later respawn cannot start fresh"
    );
    assert!(!rig.mgr.has_live_session("cody-bbbb2222"));
    assert_eq!(
        rig.mgr.conversations().get(&sid).unwrap().tag,
        "cody-aaaa1111"
    );
    assert_eq!(
        rig.mgr.session_history().tag_of(&sid).as_deref(),
        Some("cody-aaaa1111")
    );
    let mut failed = false;
    while let Ok(m) = rx.try_recv() {
        if let ServerMsg::ConversationResumeFailed { tag, reason } = m {
            assert_eq!(
                (tag.as_str(), reason.as_str()),
                ("cody-bbbb2222", "not_found_here")
            );
            failed = true;
        }
    }
    assert!(failed, "the app was told");
}

// ── nudges and the operator-only channel ──────────────────────────────────────

#[tokio::test]
async fn the_changed_nudge_reaches_only_operator_connections_and_is_debounced() {
    let mut rig = Rig::new();
    let (op_tx, mut op_rx) = mpsc::unbounded_channel();
    let (other_tx, mut other_rx) = mpsc::unbounded_channel();
    {
        let mut senders = rig.mgr.client_senders.lock().unwrap();
        senders.insert("op".into(), op_tx);
        senders.insert("other".into(), other_tx);
    }
    rig.mgr.mark_operator_conn("op");
    rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.mgr.flush_conversation_nudge();
    rig.send("cody-aaaa1111", "again");
    rig.mgr.flush_conversation_nudge(); // inside the 500 ms window
    let mut got = 0;
    while let Ok(m) = op_rx.try_recv() {
        assert!(matches!(m, ServerMsg::ConversationHistoryChanged { .. }));
        got += 1;
    }
    assert_eq!(got, 1);
    assert!(other_rx.try_recv().is_err());
}

// ── what the list costs ───────────────────────────────────────────────────────

fn visible_entry(history: &ConversationHistory, sid: &str, cwd: &Path, now: i64) {
    history.note_spawn(
        crate::conversations::store::SpawnNote {
            tag: "t",
            sid,
            agent: "cody",
            cwd: Some(cwd),
            title: "T",
            label: None,
            model: None,
        },
        now,
    );
    history.note_user_send(sid, "hello", false, false, now);
    history.turn_completed(sid, true, false, now);
}

#[test]
fn listing_500_entries_with_huge_files_is_fast_and_opens_nothing() {
    let _lock = CLAUDE_BIN_ENV_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var(PROJECTS_DIR_ENV, dir.path().join("projects"));
    let cwd = dir.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let folder = dir
        .path()
        .join("projects")
        .join(crate::conversations::transcript::encode_cwd(
            &cwd.to_string_lossy(),
        ));
    std::fs::create_dir_all(&folder).unwrap();
    let history = ConversationHistory::in_memory();
    let now = crate::conversations::now_ms();
    for i in 0..500 {
        let sid = format!("sid-{i}");
        let f = std::fs::File::create(folder.join(format!("{sid}.jsonl"))).unwrap();
        f.set_len(100 * 1024 * 1024).unwrap();
        visible_entry(&history, &sid, &cwd, now - i);
    }
    let opens_before = list::CONTENT_CHECKS.load(Ordering::Relaxed);
    let started = Instant::now();
    let listing = list::build(&history.snapshot(), &history, &HashMap::new());
    let took = started.elapsed();
    std::env::remove_var(PROJECTS_DIR_ENV);
    assert_eq!(listing.entries.len(), 500);
    assert!(took < Duration::from_millis(300), "{took:?}");
    assert_eq!(
        list::CONTENT_CHECKS.load(Ordering::Relaxed),
        opens_before,
        "the list path opened a transcript"
    );
    assert_eq!(
        listing.to_check.len(),
        500,
        "content checks are queued, not run"
    );
}

#[test]
fn bad_files_get_their_status_and_do_not_stop_the_good_ones() {
    let _lock = CLAUDE_BIN_ENV_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var(PROJECTS_DIR_ENV, dir.path().join("projects"));
    let cwd = dir.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let folder = dir
        .path()
        .join("projects")
        .join(crate::conversations::transcript::encode_cwd(
            &cwd.to_string_lossy(),
        ));
    std::fs::create_dir_all(&folder).unwrap();
    let history = ConversationHistory::in_memory();
    let now = crate::conversations::now_ms();
    for i in 0..50 {
        let sid = format!("good-{i}");
        std::fs::write(folder.join(format!("{sid}.jsonl")), USER_LINE).unwrap();
        visible_entry(&history, &sid, &cwd, now);
    }
    std::fs::write(folder.join("binary.jsonl"), [0u8, 159, 146, 150]).unwrap();
    std::fs::write(folder.join("empty.jsonl"), "").unwrap();
    std::fs::write(folder.join("truncated.jsonl"), "garbage that is not json").unwrap();
    for sid in ["binary", "empty", "truncated", "deleted"] {
        visible_entry(&history, sid, &cwd, now);
    }
    history.note_not_found("deleted");
    // The background pass checks the first bytes of what has not been checked.
    let first = list::build(&history.snapshot(), &history, &HashMap::new());
    list::run_background(&history, &first.to_check, &first.to_locate);
    let listing = list::build(&history.snapshot(), &history, &HashMap::new());
    std::env::remove_var(PROJECTS_DIR_ENV);
    let status = |id: &str| {
        listing
            .entries
            .iter()
            .find(|e| e.id == id)
            .unwrap()
            .status
            .clone()
    };
    use crate::ipc::protocol::ConversationStatus as S;
    assert_eq!(status("binary"), S::UnavailableUnreadable);
    assert_eq!(status("empty"), S::UnavailableUnreadable);
    assert_eq!(status("truncated"), S::UnavailableUnreadable);
    assert_eq!(status("deleted"), S::UnavailableDeleted);
    for i in 0..50 {
        assert_eq!(status(&format!("good-{i}")), S::Available);
    }
}

// ── a held first message, injected turns, sensitivity ─────────────────────────

fn history_file(rig: &Rig) -> String {
    rig.mgr.conversations().flush();
    std::fs::read_to_string(ConversationHistory::path_beside(
        &rig.dir.path().join("daemon-sessions.json"),
    ))
    .unwrap_or_default()
}

#[tokio::test]
async fn a_first_message_held_for_a_sign_in_is_not_the_first_prompt() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.mgr
        .send_user_message("cody-aaaa1111", "HELDWORDS please", &[])
        .unwrap();
    // The turn failed to sign in: the message is held, not delivered.
    conversation_history::turn_completed(&rig.mgr.sessions["cody-aaaa1111"].shared, false);
    assert!(rig.mgr.conversations().snapshot().entries.is_empty());
    assert!(!history_file(&rig).contains("HELDWORDS"));
    // Delivered after the sign-in: the conversation shows, with no prompt text.
    rig.deliver("cody-aaaa1111");
    let e = rig.mgr.conversations().get(&sid).unwrap();
    assert!(e.has_turn);
    assert_eq!(e.first_prompt, FirstPrompt::None);
    assert!(!history_file(&rig).contains("HELDWORDS"));
}

/// A first message written, bound to a turn that failed to sign in: `tag` holds it.
/// Returns the hold's id. The conversation history is told nothing of the failure,
/// so the message is still its candidate: only a discard can drop it.
fn hold_first_message(rig: &mut Rig, tag: &str, text: &str) -> String {
    use crate::ipc::auth_failure::{AuthSignal, TurnAuthOutcome};
    rig.mgr.send_user_message(tag, text, &[]).unwrap();
    let shared = rig.mgr.sessions[tag].shared.clone();
    login::on_turn_started(&shared);
    login::on_turn_end(
        &shared,
        tag,
        Some(TurnAuthOutcome {
            signal: AuthSignal::ErrorField,
            resendable: true,
        }),
    );
    match rig.mgr.login_snapshot() {
        ServerMsg::ClaudeLoginState { sessions, .. } => sessions
            .into_iter()
            .find(|s| s.tag == tag)
            .and_then(|s| s.hold_id)
            .expect("a hold holding the message"),
        other => panic!("{other:?}"),
    }
}

fn assert_next_message_is_first_prompt(rig: &mut Rig, sid: &str, tag: &str) {
    rig.send(tag, "SECONDWORDS now");
    let e = rig.mgr.conversations().get(sid).unwrap();
    assert_eq!(
        e.first_prompt,
        FirstPrompt::Text("SECONDWORDS now".into()),
        "the discarded message became the first prompt"
    );
    assert!(!history_file(rig).contains("HELDWORDS"));
}

#[tokio::test]
async fn a_discarded_held_message_never_becomes_the_first_prompt() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    let hold = hold_first_message(&mut rig, "cody-aaaa1111", "HELDWORDS please");
    assert!(rig.mgr.discard_held("cody-aaaa1111", Some(&hold)));
    assert_next_message_is_first_prompt(&mut rig, &sid, "cody-aaaa1111");
}

#[tokio::test]
async fn a_held_message_stopped_by_the_user_never_becomes_the_first_prompt() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    hold_first_message(&mut rig, "cody-aaaa1111", "HELDWORDS please");
    // The failed turn has ended: the session is idle behind the hold.
    *lock_recover(&rig.mgr.sessions["cody-aaaa1111"].shared.state) = SessionState::Idle;
    let out = rig.mgr.interrupt("cody-aaaa1111").unwrap();
    assert!(matches!(out, InterruptOutcome::DiscardedHold), "{out:?}");
    assert_next_message_is_first_prompt(&mut rig, &sid, "cody-aaaa1111");
}

#[tokio::test]
async fn an_injected_message_never_becomes_the_first_prompt() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.mgr
        .inject(
            "cody-aaaa1111",
            "INJECTEDWORDS from a notice",
            "key-1".into(),
        )
        .unwrap();
    rig.deliver("cody-aaaa1111");
    assert!(
        rig.mgr.conversations().snapshot().entries.is_empty(),
        "an injected turn does not make a conversation"
    );
    assert!(!history_file(&rig).contains("INJECTEDWORDS"));
    // The user's own message does.
    rig.send("cody-aaaa1111", "REALWORDS now");
    let e = rig.mgr.conversations().get(&sid).unwrap();
    assert_eq!(e.first_prompt, FirstPrompt::Text("REALWORDS now".into()));
    assert!(!history_file(&rig).contains("INJECTEDWORDS"));
}

#[test]
fn injected_text_in_a_transcript_is_never_the_first_prompt() {
    use crate::conversations::transcript::scan;
    let line = |text: &str| {
        format!(
            "{}\n",
            serde_json::json!({"type":"user","message":{"content":text}})
        )
    };
    let body = line("Base directory for this skill: /x/skills/foo\nSKILLBODY")
        + &line("<cross-session-message from=\"a\">PEERBODY</cross-session-message>")
        + &line("This session is being continued from a previous conversation. SUMMARYBODY")
        + &line("<system-reminder>REMINDERBODY</system-reminder>")
        + &line("The real first question");
    assert_eq!(
        scan(body.as_bytes()).first_user.as_deref(),
        Some("The real first question")
    );
}

#[tokio::test]
async fn a_tag_that_becomes_sensitive_shows_no_prompt_or_branch_with_no_further_send() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "TOPSECRETWORDS plan");
    let path = rig.transcript(
        &sid,
        concat!(
            r#"{"type":"user","cwd":"/w","gitBranch":"BRANCHWORDS/x","message":{"content":"hi"}}"#,
            "\n"
        ),
    );
    let history = rig.mgr.conversations();
    crate::conversations::transcript::refresh_tail(&history, &sid);
    let before = history_file(&rig);
    assert!(
        before.contains("TOPSECRETWORDS") && before.contains("BRANCHWORDS"),
        "{before}"
    );

    // The tag becomes sensitive (a work item was sent to it); nobody sends again.
    rig.mgr.sensitive.mark_tag("cody-aaaa1111");
    let ServerMsg::ConversationHistory { entries, .. } =
        rig.mgr.conversation_history_msg("r".into())
    else {
        panic!("not a history");
    };
    let w = &entries[0];
    assert!(
        w.first_prompt.is_none() && w.branch.is_none() && w.project_path.is_none(),
        "{w:?}"
    );
    assert!(w.sensitive);
    let after = history_file(&rig);
    assert!(!after.contains("TOPSECRETWORDS"), "{after}");
    assert!(!after.contains("BRANCHWORDS"), "{after}");

    // The branch stops updating.
    std::fs::write(
        &path,
        concat!(
            r#"{"type":"user","cwd":"/w","gitBranch":"NEWBRANCHWORDS","message":{"content":"hi"}}"#,
            "\n"
        ),
    )
    .unwrap();
    history.set_transcript_path(&sid, &path);
    crate::conversations::transcript::refresh_tail(&history, &sid);
    assert!(history.get(&sid).unwrap().branch.is_none());
    assert!(!history_file(&rig).contains("NEWBRANCHWORDS"));
}

#[tokio::test]
async fn a_completed_turn_purges_a_now_sensitive_focus_without_the_list() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "ANOTHERSECRET plan");
    assert!(history_file(&rig).contains("ANOTHERSECRET"));
    rig.mgr.sensitive.mark_tag("cody-aaaa1111");
    rig.deliver("cody-aaaa1111");
    let e = rig.mgr.conversations().get(&sid).unwrap();
    assert!(e.sensitive);
    assert!(!history_file(&rig).contains("ANOTHERSECRET"));
}

// ── resume: one writer per conversation ───────────────────────────────────────

/// A conversation with a transcript, owned by the open focus `cody-aaaa1111`.
fn open_focus_with_conversation(rig: &mut Rig) -> String {
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.open_in_registry("cody-aaaa1111");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    sid
}

#[tokio::test]
async fn an_open_focus_that_owns_the_conversation_is_switched_to_after_a_daemon_restart() {
    let mut rig = Rig::new();
    let sid = open_focus_with_conversation(&mut rig);
    // `make install-daemon`: the process is gone, the focus is still open and
    // still owns the stored id.
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    assert!(load_id_store(&rig.mgr.store_path).contains_key("cody-aaaa1111"));
    let spawns = rig.argv_lines().len();
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(
        outcome(&reply),
        (
            ConversationResumeOutcome::Switch,
            Some("cody-aaaa1111".into()),
            None
        )
    );
    assert!(
        !load_id_store(&rig.mgr.store_path).contains_key("cody-bbbb2222"),
        "no second tag holds the conversation's id"
    );
    assert_eq!(
        rig.mgr.conversations().get(&sid).unwrap().tag,
        "cody-aaaa1111"
    );
    assert_eq!(rig.argv_lines().len(), spawns);
}

#[tokio::test]
async fn an_open_focus_the_crash_loop_guard_gave_up_on_is_switched_to_not_duplicated() {
    let mut rig = Rig::new();
    let sid = open_focus_with_conversation(&mut rig);
    // Dead, still known, still open, still owning the id.
    rig.mgr.stop_session("cody-aaaa1111");
    injected_tests::eventually("the child to exit", || {
        (!rig.mgr.sessions["cody-aaaa1111"].alive()).then_some(())
    })
    .await;
    assert!(rig.mgr.sessions.contains_key("cody-aaaa1111"));
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(
        outcome(&reply),
        (
            ConversationResumeOutcome::Switch,
            Some("cody-aaaa1111".into()),
            None
        )
    );
    let owners = load_id_store(&rig.mgr.store_path)
        .values()
        .filter(|id| id.as_str() == sid)
        .count();
    assert_eq!(owners, 1, "exactly one tag owns the conversation");
}

// ── the stale-id guard until the first success ────────────────────────────────

#[tokio::test]
async fn a_resumed_tag_stays_protected_until_its_first_turn_succeeds_and_across_a_restart() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    rig.spawn("cody-bbbb2222", "cody");
    assert!(rig.mgr.is_resumed_tag("cody-bbbb2222"));

    // A daemon restart before the first send keeps the protection.
    let restarted = ConversationHistory::open(ConversationHistory::path_beside(
        &rig.dir.path().join("daemon-sessions.json"),
    ));
    assert!(restarted.pending_resume_for_tag("cody-bbbb2222").is_some());

    // The first send alone does not end it: the message may fail to start.
    rig.mgr
        .send_user_message("cody-bbbb2222", "first words", &[])
        .unwrap();
    assert!(
        rig.mgr.is_resumed_tag("cody-bbbb2222"),
        "a send is not a success"
    );
    // A turn that failed to sign in is not a success either.
    conversation_history::turn_completed(&rig.mgr.sessions["cody-bbbb2222"].shared, false);
    assert!(rig.mgr.is_resumed_tag("cody-bbbb2222"));
    // The first successful turn ends it.
    rig.deliver("cody-bbbb2222");
    assert!(!rig.mgr.is_resumed_tag("cody-bbbb2222"));
}

// ── a retired model ───────────────────────────────────────────────────────────

#[tokio::test]
async fn a_resumed_conversation_on_a_retired_model_runs_on_the_default_and_the_note_names_both() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.mgr.conversations().refresh_meta(
        &sid,
        crate::conversations::store::MetaUpdate {
            model: Some(("retiredmodel-9".into(), None)),
            ..Default::default()
        },
        crate::conversations::now_ms(),
    );
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    model_store::set_default(
        &rig.mgr.model_hub.paths.defaults,
        "cody",
        Some(model_store::AgentDefault {
            model: "sonnet".into(),
            effort: None,
        }),
    )
    .unwrap();
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    let (target, note) = rig.mgr.spawn_model("cody-bbbb2222", "cody");
    assert_eq!(target.map(|t| t.model).as_deref(), Some("sonnet"));
    let note = note.expect("a one-time note");
    assert!(note.contains("retiredmodel-9"), "{note}");
    assert!(note.contains("Sonnet"), "{note}");
    assert!(note.contains("no longer available"), "{note}");
}

// ── nothing about a conversation reaches a log ────────────────────────────────

static LOG_LINES: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

struct LogCapture;

struct LogFields(String);

impl tracing::field::Visit for LogFields {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        use std::fmt::Write;
        let _ = write!(self.0, "{}={:?} ", field.name(), value);
    }
}

impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for LogCapture {
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        let mut fields = LogFields(String::new());
        event.record(&mut fields);
        LOG_LINES
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(format!("{} {}", event.metadata().target(), fields.0));
    }
}

#[tokio::test]
async fn no_first_prompt_title_label_or_branch_reaches_a_log_line() {
    use tracing_subscriber::layer::SubscriberExt;
    static INSTALL: std::sync::Once = std::sync::Once::new();
    INSTALL.call_once(|| {
        let _ = tracing::subscriber::set_global_default(
            tracing_subscriber::registry().with(LogCapture),
        );
    });
    let mut rig = Rig::new();
    let mut meta = test_focus("cody-aaaa1111");
    meta.display_name = "TITLESENTINEL-5a9d".into();
    meta.label = Some("LABELSENTINEL-77c1".into());
    rig.mgr.set_focus_registry(vec![meta]);
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "PROMPTSENTINEL-7c1e fix it");
    rig.transcript(
        &sid,
        concat!(r#"{"type":"user","cwd":"/w","gitBranch":"BRANCHSENTINEL-3e2b","message":{"content":"hi"}}"#, "\n"),
    );
    crate::conversations::transcript::refresh_tail(&rig.mgr.conversations(), &sid);
    let _ = rig.mgr.conversation_history_msg("r".into());
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    rig.mgr
        .conversations()
        .set_first_prompts_enabled(false, crate::conversations::now_ms());
    rig.mgr
        .conversations()
        .remove(&sid, crate::conversations::now_ms());
    rig.mgr.fail_resumed_tag("cody-bbbb2222");
    // A corrupt history is warned about without its content.
    let bad = rig.dir.path().join("bad-history.json");
    std::fs::write(&bad, "PROMPTSENTINEL-7c1e not json").unwrap();
    let _ = ConversationHistory::open(bad);

    let lines = LOG_LINES.lock().unwrap_or_else(|e| e.into_inner()).clone();
    assert!(!lines.is_empty(), "the capture works");
    for line in &lines {
        for needle in [
            "PROMPTSENTINEL-7c1e",
            "TITLESENTINEL-5a9d",
            "LABELSENTINEL-77c1",
            "BRANCHSENTINEL-3e2b",
        ] {
            assert!(
                !line.contains(needle),
                "{needle} leaked into a log line: {line}"
            );
        }
    }
}

// ── the transcript folder is a boundary ───────────────────────────────────────

#[test]
fn the_content_check_never_opens_a_file_behind_a_symlinked_project_folder() {
    let _lock = CLAUDE_BIN_ENV_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let projects = dir.path().join("projects");
    let outside = dir.path().join("outside");
    std::fs::create_dir_all(&projects).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("esc-sid.jsonl"), USER_LINE).unwrap();
    std::os::unix::fs::symlink(&outside, projects.join("linked")).unwrap();
    std::env::set_var(PROJECTS_DIR_ENV, &projects);
    let history = ConversationHistory::open(dir.path().join("conversation-history.json"));
    history.note_spawn(
        crate::conversations::store::SpawnNote {
            tag: "cody-aaaa1111",
            sid: "esc-sid",
            agent: "cody",
            cwd: None,
            title: "A title",
            label: None,
            model: None,
        },
        crate::conversations::now_ms(),
    );
    history.set_transcript_path("esc-sid", &projects.join("linked").join("esc-sid.jsonl"));
    list::run_background(&history, &["esc-sid".to_owned()], &[]);
    std::env::remove_var(PROJECTS_DIR_ENV);
    assert!(
        history.verdict("esc-sid").is_some_and(|v| v.unreadable),
        "a file outside the projects folder was read"
    );
}

#[test]
fn a_symlinked_project_folder_never_leads_a_read_out_of_the_projects_folder() {
    let _lock = CLAUDE_BIN_ENV_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let projects = dir.path().join("projects");
    let outside = dir.path().join("outside");
    std::fs::create_dir_all(&projects).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("escape-sid.jsonl"), USER_LINE).unwrap();
    std::os::unix::fs::symlink(&outside, projects.join("linked")).unwrap();
    std::env::set_var(PROJECTS_DIR_ENV, &projects);
    let located = crate::conversations::transcript::locate("escape-sid");
    let safe = crate::conversations::transcript::is_safe_transcript(
        &projects.join("linked").join("escape-sid.jsonl"),
    );
    // A regular file inside is found.
    std::fs::create_dir_all(projects.join("real")).unwrap();
    std::fs::write(projects.join("real").join("ok-sid.jsonl"), USER_LINE).unwrap();
    let found = crate::conversations::transcript::locate("ok-sid");
    std::env::remove_var(PROJECTS_DIR_ENV);
    assert!(
        located.is_none(),
        "followed a symlinked folder out: {located:?}"
    );
    assert!(!safe);
    assert!(found.is_some());
}
