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
        let folder = self
            .dir
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
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
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
    rig.mgr
        .send_user_message("picks-x", "UNIQUEPICKSWORD", &[])
        .unwrap();
    assert!(rig.mgr.conversations().get(&sid).is_none());
}

#[tokio::test]
async fn a_sensitive_agent_stores_no_first_prompt_and_no_branch() {
    let mut rig = Rig::new();
    let sid = rig.spawn("teri", "teri");
    rig.mgr.send_user_message("teri", "plan my week", &[]).unwrap();
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
    rig.mgr
        .send_user_message("cody-aaaa1111", "SSN was 219-09-9999 ok", &[])
        .unwrap();
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
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
    let path = ConversationHistory::path_beside(&rig.dir.path().join("daemon-sessions.json"));
    assert_eq!(std::fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
}

// ── resume ────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn resuming_a_conversation_running_in_an_open_focus_switches_and_starts_nothing() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.open_in_registry("cody-aaaa1111");
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
    rig.transcript(&sid, USER_LINE);
    let spawns = rig.wait_spawns(1).await.len();
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(
        outcome(&reply),
        (ConversationResumeOutcome::Switch, Some("cody-aaaa1111".into()), None)
    );
    assert_eq!(rig.argv_lines().len(), spawns, "no process was started");
}

#[tokio::test]
async fn a_removed_focus_with_a_live_child_is_stopped_then_resumed_once() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
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
    assert!(lines[1].contains(&format!("--resume {sid}")), "{}", lines[1]);
    assert_eq!(lines.len(), 2);
    // The conversation now belongs to the new tag, and origin verification follows.
    assert_eq!(rig.mgr.conversations().get(&sid).unwrap().tag, "cody-bbbb2222");
    assert_eq!(rig.mgr.session_history().tag_of(&sid).as_deref(), Some("cody-bbbb2222"));
    assert!(rig.mgr.session_history().contains("cody-aaaa1111", &sid));
}

#[tokio::test]
async fn a_second_resume_of_the_same_conversation_switches_to_the_first_tag() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
    rig.transcript(&sid, USER_LINE);
    let first = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&first).0, ConversationResumeOutcome::Ready);
    let second = rig.mgr.resume_conversation(&sid, "cody-cccc3333");
    assert_eq!(
        outcome(&second),
        (ConversationResumeOutcome::Switch, Some("cody-bbbb2222".into()), None)
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
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
    rig.transcript(&sid, USER_LINE);
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    let before = std::fs::read_to_string(rig.dir.path().join("stdin.log")).unwrap_or_default();
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    let record =
        model_store::focus_record(&rig.mgr.model_hub.paths.focus_models, "cody-bbbb2222").unwrap();
    assert_eq!((record.model.as_str(), record.effort.as_deref()), ("opus", Some("high")));
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
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
    rig.transcript(&sid, USER_LINE);
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
            if (words[i] == "--resume" || words[i] == "--session-id") && words.get(i + 1) == Some(&sid) {
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
    assert_eq!(strip(&lines[1], &sid), strip(&lines[2], &fresh_sid).iter().map(|w| w.replace("cody-cccc3333", "cody-bbbb2222")).collect::<Vec<_>>());
}

#[tokio::test]
async fn unavailable_and_missing_conversations_are_refused() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
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
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
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
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
    rig.transcript(&sid, USER_LINE);
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    // An operator connection to hear about it.
    let (tx, mut rx) = mpsc::unbounded_channel();
    rig.mgr.client_senders.lock().unwrap().insert("op".into(), tx);
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
    assert!(!rig.mgr.has_live_session("cody-bbbb2222"));
    assert_eq!(rig.mgr.conversations().get(&sid).unwrap().tag, "cody-aaaa1111");
    assert_eq!(rig.mgr.session_history().tag_of(&sid).as_deref(), Some("cody-aaaa1111"));
    let mut failed = false;
    while let Ok(m) = rx.try_recv() {
        if let ServerMsg::ConversationResumeFailed { tag, reason } = m {
            assert_eq!((tag.as_str(), reason.as_str()), ("cody-bbbb2222", "not_found_here"));
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
    rig.mgr
        .send_user_message("cody-aaaa1111", "hello", &[])
        .unwrap();
    rig.mgr.flush_conversation_nudge();
    rig.mgr
        .send_user_message("cody-aaaa1111", "again", &[])
        .unwrap();
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
}

#[test]
fn listing_500_entries_with_huge_files_is_fast_and_opens_nothing() {
    let _lock = CLAUDE_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var(PROJECTS_DIR_ENV, dir.path().join("projects"));
    let cwd = dir.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let folder = dir
        .path()
        .join("projects")
        .join(crate::conversations::transcript::encode_cwd(&cwd.to_string_lossy()));
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
    assert_eq!(listing.to_check.len(), 500, "content checks are queued, not run");
}

#[test]
fn bad_files_get_their_status_and_do_not_stop_the_good_ones() {
    let _lock = CLAUDE_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var(PROJECTS_DIR_ENV, dir.path().join("projects"));
    let cwd = dir.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let folder = dir
        .path()
        .join("projects")
        .join(crate::conversations::transcript::encode_cwd(&cwd.to_string_lossy()));
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
    let status = |id: &str| listing.entries.iter().find(|e| e.id == id).unwrap().status.clone();
    use crate::ipc::protocol::ConversationStatus as S;
    assert_eq!(status("binary"), S::UnavailableUnreadable);
    assert_eq!(status("empty"), S::UnavailableUnreadable);
    assert_eq!(status("truncated"), S::UnavailableUnreadable);
    assert_eq!(status("deleted"), S::UnavailableDeleted);
    for i in 0..50 {
        assert_eq!(status(&format!("good-{i}")), S::Available);
    }
}
