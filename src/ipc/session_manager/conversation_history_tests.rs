//! The conversation history through a real `SessionManager` and a stub `claude`
//! that records its argv and stdin. Temp dirs only; all text is invented.

use super::tests::CLAUDE_BIN_ENV_LOCK;
use super::*;
use crate::conversations::list;
use crate::conversations::transcript::PROJECTS_DIR_ENV;
use crate::conversations::SPACES_ROOT_ENV;
use crate::conversations::{ConversationHistory, FirstPrompt, Reason};
use crate::ipc::protocol::{ConversationResumeOutcome, ConversationStatus};
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
        std::env::remove_var(SPACES_ROOT_ENV);
        std::env::remove_var("NOSTROMO_QA_DAEMON");
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
                "#!/bin/sh\necho \"$@\" >> '{argv}'\npwd -P >> '{cwdlog}'\ncat >> '{stdin}'\n",
                argv = dir.path().join("argv.log").display(),
                cwdlog = dir.path().join("cwd.log").display(),
                stdin = dir.path().join("stdin.log").display(),
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::env::set_var(CLAUDE_BIN_ENV, &script);
        std::env::set_var(PROJECTS_DIR_ENV, dir.path().join("projects"));
        // No-codebase folders live under the temp dir, never under the real home.
        std::env::set_var("NOSTROMO_QA_DAEMON", "1");
        std::env::set_var(SPACES_ROOT_ENV, dir.path().join("spaces"));
        std::fs::create_dir_all(dir.path().join("spaces")).unwrap();
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

    /// Spawns the stub and returns once it has logged its argv. A test that
    /// stops the session straight after spawning would otherwise race the
    /// stub's first line: on a loaded machine the SIGKILL lands before the
    /// script has run, the line never comes, and a later `wait_spawns(n)`
    /// waits for it in vain.
    fn spawn(&mut self, tag: &str, agent: &str) -> String {
        let logged = self.argv_lines().len();
        let sid = self
            .mgr
            .spawn_session(
                tag.into(),
                agent.into(),
                "View".into(),
                Some(self.cwd.clone()),
                None,
                false,
            )
            .unwrap()
            .expect("a session id");
        let deadline = Instant::now() + Duration::from_secs(30);
        while self.argv_lines().len() <= logged {
            assert!(Instant::now() < deadline, "the stub never logged its argv");
            std::thread::sleep(Duration::from_millis(5));
        }
        sid
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

    /// The directory each spawn of the stub ran in, in order.
    fn cwd_lines(&self) -> Vec<PathBuf> {
        std::fs::read_to_string(self.dir.path().join("cwd.log"))
            .unwrap_or_default()
            .lines()
            .map(PathBuf::from)
            .collect()
    }

    fn stdin_log(&self) -> String {
        std::fs::read_to_string(self.dir.path().join("stdin.log")).unwrap_or_default()
    }

    /// A main checkout (a `.git` folder on `main_branch`) and a linked worktree
    /// of it (a `.git` file naming it).
    fn linked_worktree(&self, main_branch: &str) -> (PathBuf, PathBuf) {
        let main = self.dir.path().join("main-repo");
        let wt = self.dir.path().join("wt-gone");
        let admin = main.join(".git").join("worktrees").join("wt-gone");
        std::fs::create_dir_all(&admin).unwrap();
        std::fs::write(
            main.join(".git").join("HEAD"),
            format!("ref: refs/heads/{main_branch}\n"),
        )
        .unwrap();
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();
        (main, wt)
    }

    /// A conversation `cody-aaaa1111` that ran on branch `old_branch` in a
    /// linked worktree that is gone now. Returns `(sid, main, worktree)`.
    async fn gone_worktree_conversation(
        &mut self,
        main_branch: &str,
        old_branch: &str,
    ) -> (String, PathBuf, PathBuf) {
        let (main, wt) = self.linked_worktree(main_branch);
        self.cwd = wt.clone();
        let sid = self.spawn("cody-aaaa1111", "cody");
        self.send("cody-aaaa1111", "hello");
        self.transcript(
            &sid,
            &format!(
                "{{\"type\":\"user\",\"cwd\":\"/w\",\"gitBranch\":\"{old_branch}\",\"message\":{{\"content\":\"hi\"}}}}\n"
            ),
        );
        crate::conversations::transcript::refresh_tail(&self.mgr.conversations(), &sid);
        self.wait_spawns(1).await;
        self.mgr.stop_session("cody-aaaa1111");
        self.mgr.sessions.remove("cody-aaaa1111");
        std::fs::remove_dir_all(&wt).unwrap();
        (sid, main, wt)
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
        age(&path, 3600);
        path
    }

    fn open_in_registry(&mut self, tag: &str) {
        let mut meta = test_focus(tag);
        meta.agent_name = "cody".into();
        self.mgr.set_focus_registry(vec![meta]);
    }
}

/// Make `path` look last written `secs_ago` seconds ago (a transcript written a
/// moment ago reads as "open in another Claude window").
fn age(path: &Path, secs_ago: u64) {
    let when = std::time::SystemTime::now() - Duration::from_secs(secs_ago);
    std::fs::File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(when)
        .unwrap();
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
        no_codebase: None,
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
            no_codebase: false,
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
        age(&folder.join(format!("{sid}.jsonl")), 3600);
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

#[tokio::test]
async fn no_first_prompt_title_label_or_branch_reaches_a_log_line() {
    crate::test_log::install_global_capture();
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

    let lines = crate::test_log::global_lines();
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
            no_codebase: false,
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

// ── resume when the worktree is gone ─────────────────────────────────────────

fn place(path: &Path) -> ResumeOptions<'_> {
    ResumeOptions {
        place: path.to_str(),
        confirm_active_elsewhere: false,
        ..Default::default()
    }
}

#[tokio::test]
async fn a_conversation_whose_worktree_is_gone_resumes_in_the_main_checkout() {
    let mut rig = Rig::new();
    let (sid, main, wt) = rig.gone_worktree_conversation("trunk", "feature/old").await;
    let entry = rig.mgr.conversations().get(&sid).unwrap();
    assert_eq!(
        list::status_now(&entry, &rig.mgr.conversations(), None),
        ConversationStatus::FolderGone {
            worktree: true,
            active_elsewhere: false
        }
    );
    let before = rig.stdin_log();

    let reply = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&main));
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    let ServerMsg::ConversationResumeResult { project_path, .. } = &reply else {
        panic!()
    };
    assert_eq!(project_path.as_deref(), main.to_str());
    assert_eq!(
        rig.mgr
            .conversations()
            .get(&sid)
            .unwrap()
            .project_path
            .as_deref(),
        main.to_str()
    );

    // The app's focus still names the old folder: the spawn goes to the main checkout.
    rig.spawn("cody-bbbb2222", "cody");
    let lines = rig.wait_spawns(2).await;
    assert_eq!(rig.cwd_lines()[1], main.canonicalize().unwrap());
    let argv = &lines[1];
    assert_eq!(
        argv.matches("--append-system-prompt").count(),
        1,
        "exactly one flag: {argv}"
    );
    for needle in [
        wt.to_str().unwrap(),
        main.to_str().unwrap(),
        "feature/old",
        "trunk",
    ] {
        assert!(argv.contains(needle), "the notice names {needle}: {argv}");
    }
    assert!(argv.contains(&format!("--resume {sid}")), "{argv}");

    // A restart of the tag tells the agent again, in the same place.
    rig.mgr.stop_session("cody-bbbb2222");
    rig.mgr.sessions.remove("cody-bbbb2222");
    rig.spawn("cody-bbbb2222", "cody");
    let lines = rig.wait_spawns(3).await;
    assert_eq!(
        lines[2].matches("--append-system-prompt").count(),
        1,
        "{}",
        lines[2]
    );
    assert!(lines[2].contains("feature/old"), "{}", lines[2]);
    assert_eq!(rig.cwd_lines()[2], main.canonicalize().unwrap());

    // Nothing was typed into the conversation: the notice rides the spawn.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(rig.stdin_log(), before, "no user turn was written");
    assert!(
        rig.mgr
            .resume_place_for("cody-bbbb2222", &sid)
            .unwrap()
            .shown
    );
}

#[tokio::test]
async fn the_notice_names_one_branch_when_both_places_are_on_it() {
    let mut rig = Rig::new();
    let (sid, main, _wt) = rig.gone_worktree_conversation("same", "same").await;
    rig.mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&main));
    let notice = rig
        .mgr
        .resume_place_for("cody-bbbb2222", &sid)
        .unwrap()
        .notice;
    assert!(!notice.contains("It was on"), "{notice}");
}

#[tokio::test]
async fn a_resume_into_another_place_adds_to_hueys_system_prompt_not_a_second_flag() {
    let mut args = vec![
        "--append-system-prompt".to_owned(),
        "PERSONA".to_owned(),
        "-n".to_owned(),
        "v".to_owned(),
    ];
    conversation_history::append_system_prompt_extra(&mut args, "NOTICE");
    assert_eq!(
        args.iter()
            .filter(|a| *a == "--append-system-prompt")
            .count(),
        1
    );
    assert_eq!(args[1], "PERSONA\n\nNOTICE");
    let mut bare = vec!["-n".to_owned()];
    conversation_history::append_system_prompt_extra(&mut bare, "NOTICE");
    assert_eq!(bare, ["-n", "--append-system-prompt", "NOTICE"]);
}

#[tokio::test]
async fn a_gone_folder_without_a_matching_main_checkout_is_refused() {
    let mut rig = Rig::new();
    let (sid, main, _wt) = rig.gone_worktree_conversation("trunk", "b").await;
    // No place asked for.
    let none = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&none).2.as_deref(), Some("folder_gone"));
    // A place that is not the conversation's own main checkout.
    let other = rig.dir.path().join("other-repo");
    std::fs::create_dir_all(other.join(".git")).unwrap();
    let wrong = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&other));
    assert_eq!(outcome(&wrong).2.as_deref(), Some("folder_gone"));
    // Its main checkout is gone too.
    std::fs::remove_dir_all(&main).unwrap();
    let gone = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&main));
    assert_eq!(outcome(&gone).2.as_deref(), Some("folder_gone"));
    assert!(!load_id_store(&rig.mgr.store_path).contains_key("cody-bbbb2222"));
    assert_eq!(rig.argv_lines().len(), 1, "nothing was started");
}

#[tokio::test]
async fn a_plain_folder_that_is_gone_has_no_main_checkout_to_resume_in() {
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.wait_spawns(1).await;
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    std::fs::remove_dir_all(&rig.cwd).unwrap();
    let elsewhere = rig.dir.path().to_path_buf();
    let reply = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&elsewhere));
    assert_eq!(outcome(&reply).2.as_deref(), Some("folder_gone"));
}

// ── active elsewhere ──────────────────────────────────────────────────────────

/// A conversation whose child is stopped, its transcript last written `secs_ago`.
async fn stopped_conversation(rig: &mut Rig, secs_ago: u64) -> (String, PathBuf) {
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    let path = rig.transcript(&sid, USER_LINE);
    rig.wait_spawns(1).await;
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    // The file was last written by someone else, some time after any stop of ours.
    rig.mgr.conversations().clear_stopped(&sid);
    age(&path, secs_ago);
    (sid, path)
}

#[tokio::test]
async fn a_transcript_written_in_the_last_two_minutes_is_active_elsewhere_unless_running() {
    let mut rig = Rig::new();
    let (sid, path) = stopped_conversation(&mut rig, 30).await;
    let history = rig.mgr.conversations();
    let entry = history.get(&sid).unwrap();
    assert_eq!(
        list::status_now(&entry, &history, None),
        ConversationStatus::ActiveElsewhere
    );
    // A Nostromo session running it is not "elsewhere".
    let live = ("cody-aaaa1111".to_owned(), true);
    assert_eq!(
        list::status_now(&entry, &history, Some(&live)),
        ConversationStatus::Running {
            tag: "cody-aaaa1111".into(),
            open: true
        }
    );
    age(&path, 180);
    assert_eq!(
        list::status_now(&entry, &history, None),
        ConversationStatus::Available
    );
}

#[tokio::test]
async fn an_unconfirmed_resume_of_an_active_elsewhere_conversation_is_refused_and_starts_nothing() {
    let mut rig = Rig::new();
    let (sid, _path) = stopped_conversation(&mut rig, 30).await;
    let refused = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&refused).2.as_deref(), Some("active_elsewhere"));
    assert!(!load_id_store(&rig.mgr.store_path).contains_key("cody-bbbb2222"));
    assert_eq!(
        rig.mgr.conversations().get(&sid).unwrap().tag,
        "cody-aaaa1111",
        "the conversation stays with its owner"
    );
    assert_eq!(rig.argv_lines().len(), 1, "nothing was spawned");

    let confirmed = rig.mgr.resume_conversation_with(
        &sid,
        "cody-bbbb2222",
        ResumeOptions {
            place: None,
            confirm_active_elsewhere: true,
            ..Default::default()
        },
    );
    assert_eq!(outcome(&confirmed).0, ConversationResumeOutcome::Ready);
}

// ── rename ────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_renamed_conversation_lists_and_resumes_under_the_new_name_and_claudes_file_is_untouched()
{
    let mut rig = Rig::new();
    let (sid, path) = stopped_conversation(&mut rig, 3600).await;
    let before = std::fs::read(&path).unwrap();
    let history = rig.mgr.conversations();
    let long = "x".repeat(80);
    assert_eq!(
        crate::conversations::normalized_title(Some(&format!("  {long}  ")))
            .unwrap()
            .chars()
            .count(),
        60
    );
    assert!(history.rename(
        &sid,
        crate::conversations::normalized_title(Some("  Picker rewrite  ")),
        crate::conversations::now_ms()
    ));
    let ServerMsg::ConversationHistory { entries, .. } =
        rig.mgr.conversation_history_msg("r".into())
    else {
        panic!()
    };
    assert_eq!(entries[0].title, "Picker rewrite");

    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    let ServerMsg::ConversationResumeResult { label, title, .. } = &reply else {
        panic!()
    };
    assert_eq!(label.as_deref(), Some("Picker rewrite"));
    assert_eq!(title.as_deref(), Some("Picker rewrite"));
    assert_eq!(std::fs::read(&path).unwrap(), before, "byte-identical");

    // An empty name clears it.
    history.rename(&sid, crate::conversations::normalized_title(Some("   ")), 0);
    assert!(history.get(&sid).unwrap().user_title.is_none());
}

// ── the tracker board follows ─────────────────────────────────────────────────

fn tracker_rig(rig: &Rig) -> (Arc<crate::tracker::TrackerRegistry>, PathBuf) {
    use crate::tracker::registry::{OpenArgs, RegistryParts};
    let base = rig.dir.path().canonicalize().unwrap();
    let repo = base.join("board-repo");
    std::fs::create_dir_all(repo.join(".git")).unwrap();
    let home = base.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let reg = Arc::new(crate::tracker::TrackerRegistry::new(
        RegistryParts::hermetic(
            base.join("tracker-state"),
            home,
            Arc::new(crate::tracker::FakeClock::at_secs(1_760_540_000)),
        ),
    ));
    let args = OpenArgs {
        topic: Some("work".into()),
        cwd: repo,
        ..Default::default()
    };
    let path = reg.open("cody-aaaa1111", "s", &args).unwrap().path;
    (reg, path)
}

#[tokio::test]
async fn the_resumed_focus_is_bound_to_the_board_the_conversation_had() {
    let mut rig = Rig::new();
    let (reg, board) = tracker_rig(&rig);
    rig.mgr.configure_tracker_frame_provider(reg.clone());
    let (sid, _) = stopped_conversation(&mut rig, 3600).await;
    assert_eq!(
        rig.mgr
            .conversations()
            .get(&sid)
            .unwrap()
            .tracker_board
            .as_deref(),
        board.to_str(),
        "each send records the bound board"
    );
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    assert_eq!(
        reg.bound_path("cody-bbbb2222").as_deref(),
        Some(board.as_path())
    );
}

#[tokio::test]
async fn a_board_that_is_gone_binds_nothing_and_creates_nothing_on_resume() {
    let mut rig = Rig::new();
    let (reg, board) = tracker_rig(&rig);
    rig.mgr.configure_tracker_frame_provider(reg.clone());
    let (sid, _) = stopped_conversation(&mut rig, 3600).await;
    std::fs::remove_file(&board).unwrap();
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    assert!(reg.bound_path("cody-bbbb2222").is_none());
    assert!(!board.exists(), "a missing board is never created");
}

// ── Mother and sensitivity follow ─────────────────────────────────────────────

#[tokio::test]
async fn a_resume_moves_the_conversation_for_mother_and_removing_the_entry_does_not_undo_it() {
    let mut rig = Rig::new();
    let (sid, _) = stopped_conversation(&mut rig, 3600).await;
    let history = rig.mgr.session_history();
    assert_eq!(
        history.current_tag(
            crate::mother::origin::session_prefix(&sid).as_deref(),
            "cody-aaaa1111"
        ),
        "cody-aaaa1111"
    );
    rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(
        history.current_tag(
            crate::mother::origin::session_prefix(&sid).as_deref(),
            "cody-aaaa1111"
        ),
        "cody-bbbb2222"
    );
    let now = crate::conversations::now_ms();
    rig.mgr.conversations().remove(&sid, now);
    rig.mgr.conversations().purge_removed(now);
    assert!(rig.mgr.conversations().get(&sid).is_none());
    assert_eq!(
        history.current_tag(
            crate::mother::origin::session_prefix(&sid).as_deref(),
            "cody-aaaa1111"
        ),
        "cody-bbbb2222",
        "the job still shows its origin"
    );
}

#[tokio::test]
async fn a_resumed_sensitive_conversation_is_sensitive_to_a_network_peer_from_its_first_frame() {
    use crate::ipc::peer::redact_for_network;
    use crate::ipc::protocol::SessionInfo;
    use crate::ipc::stream_json::SessionState;
    let mut rig = Rig::new();
    let (sid, _) = stopped_conversation(&mut rig, 3600).await;
    // The tag became sensitive after its last send: the entry never heard.
    rig.mgr.sensitive.mark_tag("cody-aaaa1111");
    assert!(!rig.mgr.conversations().get(&sid).unwrap().sensitive);

    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    // No spawn has happened yet: the frames the Mac's new focus causes are
    // already redacted.
    let mut meta = test_focus("cody-bbbb2222");
    meta.display_name = "SECRET TITLE".into();
    let ServerMsg::FocusRegistryUpdated { focuses, .. } = redact_for_network(
        ServerMsg::FocusRegistryUpdated {
            focuses: vec![meta],
            host: None,
        },
        &rig.mgr.sensitive,
    ) else {
        panic!()
    };
    assert_eq!(focuses[0].display_name, "cody", "{focuses:?}");
    assert_ne!(focuses[0].tag, "cody-bbbb2222", "the tag is opaque");
    let info = SessionInfo {
        tag: "cody-bbbb2222".into(),
        agent_name: "cody".into(),
        view_name: "v".into(),
        session_id: None,
        alive: true,
        remote_control: false,
        state: SessionState::Idle,
        stop_reason: None,
        mcp_bridge_connected: None,
        agent_turns: None,
        agent_messages: None,
        agent_problems: None,
        activity_epoch: None,
        last_problem: None,
    };
    let ServerMsg::SessionListResp { sessions, .. } = redact_for_network(
        ServerMsg::SessionListResp {
            sessions: vec![info],
            host: None,
        },
        &rig.mgr.sensitive,
    ) else {
        panic!()
    };
    assert!(sessions.is_empty(), "a sensitive session is not listed");
    assert!(
        rig.mgr.conversations().get(&sid).unwrap().sensitive,
        "the entry is marked at resume time too"
    );
}

// ── a gone worktree is also checked for "open elsewhere" ─────────────────────

fn set_mtime(path: &Path, when: std::time::SystemTime) {
    std::fs::File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(when)
        .unwrap();
}

fn transcript_of(rig: &Rig, sid: &str, wt: &Path) -> PathBuf {
    rig.dir
        .path()
        .join("projects")
        .join(crate::conversations::transcript::encode_cwd(
            &wt.to_string_lossy(),
        ))
        .join(format!("{sid}.jsonl"))
}

fn confirmed_in(path: &Path) -> ResumeOptions<'_> {
    ResumeOptions {
        place: path.to_str(),
        confirm_active_elsewhere: true,
        ..Default::default()
    }
}

#[tokio::test]
async fn a_gone_worktree_written_to_a_moment_ago_needs_both_confirmations() {
    let mut rig = Rig::new();
    let (sid, main, wt) = rig.gone_worktree_conversation("trunk", "feature/old").await;
    let path = transcript_of(&rig, &sid, &wt);
    rig.mgr.conversations().clear_stopped(&sid);
    age(&path, 30);
    let history = rig.mgr.conversations();
    let entry = history.get(&sid).unwrap();
    assert_eq!(
        list::status_now(&entry, &history, None),
        ConversationStatus::FolderGone {
            worktree: true,
            active_elsewhere: true
        }
    );

    // The place alone is not enough: the daemon refuses and starts nothing.
    let no_confirm = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&main));
    assert_eq!(outcome(&no_confirm).2.as_deref(), Some("active_elsewhere"));
    assert!(!load_id_store(&rig.mgr.store_path).contains_key("cody-bbbb2222"));
    let e = history.get(&sid).unwrap();
    assert_eq!(e.tag, "cody-aaaa1111");
    assert_eq!(e.project_path.as_deref(), wt.to_str(), "nothing moved");
    assert!(rig.mgr.resume_place_for("cody-bbbb2222", &sid).is_none());

    // The confirmation alone is not enough: there is still the folder.
    let no_place = rig.mgr.resume_conversation_with(
        &sid,
        "cody-bbbb2222",
        ResumeOptions {
            place: None,
            confirm_active_elsewhere: true,
            ..Default::default()
        },
    );
    assert_eq!(outcome(&no_place).2.as_deref(), Some("folder_gone"));

    // Both: it goes.
    let both = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", confirmed_in(&main));
    assert_eq!(outcome(&both).0, ConversationResumeOutcome::Ready);
}

#[tokio::test]
async fn a_gone_worktree_last_written_two_minutes_ago_needs_only_the_place() {
    let mut rig = Rig::new();
    let (sid, main, wt) = rig.gone_worktree_conversation("trunk", "feature/old").await;
    rig.mgr.conversations().clear_stopped(&sid);
    age(&transcript_of(&rig, &sid, &wt), 180);
    let quiet = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&main));
    assert_eq!(outcome(&quiet).0, ConversationResumeOutcome::Ready);
}

// ── a resume that does not open undoes the move ───────────────────────────────

#[tokio::test]
async fn a_cancelled_resume_into_the_main_checkout_leaves_the_conversation_in_its_gone_worktree() {
    let mut rig = Rig::new();
    let (reg, board) = tracker_rig(&rig);
    rig.mgr.configure_tracker_frame_provider(reg.clone());
    let (sid, main, wt) = rig.gone_worktree_conversation("trunk", "feature/old").await;
    let before = rig.mgr.conversations().get(&sid).unwrap();
    let reply = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&main));
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    assert_eq!(
        reg.bound_path("cody-bbbb2222").as_deref(),
        Some(board.as_path())
    );

    rig.mgr.release_resumed_tag("cody-bbbb2222");

    let after = rig.mgr.conversations().get(&sid).unwrap();
    assert_eq!(after.project_path, before.project_path);
    assert_eq!(after.main_checkout, before.main_checkout);
    assert_eq!(after.project_path.as_deref(), wt.to_str());
    assert!(rig.mgr.resume_place_for("cody-bbbb2222", &sid).is_none());
    assert!(
        reg.bound_path("cody-bbbb2222").is_none(),
        "the board binding is undone"
    );
    // The row reads "worktree gone" again, and a resume without the choice is refused.
    assert_eq!(
        list::status_now(&after, &rig.mgr.conversations(), None),
        ConversationStatus::FolderGone {
            worktree: true,
            active_elsewhere: false
        }
    );
    let again = rig.mgr.resume_conversation(&sid, "cody-cccc3333");
    assert_eq!(outcome(&again).2.as_deref(), Some("folder_gone"));
}

#[tokio::test]
async fn a_failed_resume_into_the_main_checkout_puts_the_folder_and_the_board_back() {
    let mut rig = Rig::new();
    let (reg, _board) = tracker_rig(&rig);
    rig.mgr.configure_tracker_frame_provider(reg.clone());
    let (sid, main, wt) = rig.gone_worktree_conversation("trunk", "feature/old").await;
    let before = rig.mgr.conversations().get(&sid).unwrap();
    rig.mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&main));
    rig.spawn("cody-bbbb2222", "cody");

    rig.mgr.fail_resumed_tag("cody-bbbb2222");

    let after = rig.mgr.conversations().get(&sid).unwrap();
    assert_eq!(after.project_path.as_deref(), wt.to_str());
    assert_eq!(after.main_checkout, before.main_checkout);
    assert_eq!(after.tag, "cody-aaaa1111");
    assert!(rig.mgr.resume_place_for("cody-bbbb2222", &sid).is_none());
    assert!(reg.bound_path("cody-bbbb2222").is_none());
    let again = rig.mgr.resume_conversation(&sid, "cody-cccc3333");
    assert_eq!(outcome(&again).2.as_deref(), Some("folder_gone"));
}

// ── the place record: per conversation, cleared, bounded ──────────────────────

#[tokio::test]
async fn the_place_belongs_to_its_conversation_and_goes_with_new_session_or_the_closed_focus() {
    let mut rig = Rig::new();
    let (sid, main, _wt) = rig.gone_worktree_conversation("trunk", "feature/old").await;
    rig.mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&main));
    assert!(rig.mgr.resume_place_for("cody-bbbb2222", &sid).is_some());
    assert!(
        rig.mgr
            .resume_place_for("cody-bbbb2222", "some-other-conversation")
            .is_none(),
        "another conversation under the tag has no place"
    );

    // New Session.
    rig.mgr.new_session("cody-bbbb2222");
    assert!(rig.mgr.resume_place_for("cody-bbbb2222", &sid).is_none());
}

#[tokio::test]
async fn the_place_goes_when_its_focus_is_removed() {
    let mut rig = Rig::new();
    let (sid2, main2, _wt2) = rig.gone_worktree_conversation("trunk", "feature/old").await;
    rig.mgr
        .resume_conversation_with(&sid2, "cody-dddd4444", place(&main2));
    rig.mgr
        .set_focus_registry(vec![test_focus("cody-dddd4444")]);
    assert!(rig.mgr.resume_place_for("cody-dddd4444", &sid2).is_some());
    rig.mgr.set_focus_registry(vec![test_focus("cody-other")]);
    rig.mgr.set_focus_registry(vec![test_focus("cody-other")]);
    assert!(rig.mgr.resume_place_for("cody-dddd4444", &sid2).is_none());
}

#[tokio::test]
async fn the_place_file_is_bounded() {
    let rig = Rig::new();
    let now = crate::conversations::now_ms();
    for i in 0..70 {
        rig.mgr.insert_place(
            &format!("cody-{i:04}"),
            conversation_history::ResumePlace {
                path: "/m".into(),
                notice: "n".into(),
                shown: false,
                sid: format!("sid-{i}"),
                old_path: None,
                old_main: None,
                old_no_codebase: false,
                no_codebase: false,
                at_ms: now + i,
            },
        );
    }
    let places = rig.mgr.load_places();
    assert_eq!(places.len(), 64);
    assert!(!places.contains_key("cody-0000"), "the oldest went first");
    assert!(places.contains_key("cody-0069"));
}

#[tokio::test]
async fn an_old_place_is_dropped_whatever_the_count() {
    let rig = Rig::new();
    let place = |sid: &str, at_ms: i64| conversation_history::ResumePlace {
        path: "/m".into(),
        notice: "n".into(),
        shown: false,
        sid: sid.into(),
        old_path: None,
        old_main: None,
        old_no_codebase: false,
        no_codebase: false,
        at_ms,
    };
    rig.mgr.insert_place("cody-old", place("sid-old", 1));
    rig.mgr
        .insert_place("cody-new", place("sid-new", crate::conversations::now_ms()));
    let places = rig.mgr.load_places();
    assert!(!places.contains_key("cody-old"), "older than 90 days");
    assert!(places.contains_key("cody-new"));
}

// ── a sensitive conversation can still be resumed in its main checkout ────────

#[tokio::test]
async fn a_sensitive_gone_worktree_entry_carries_its_main_checkout_and_nothing_else_of_the_path() {
    let mut rig = Rig::new();
    let (sid, main, _wt) = rig.gone_worktree_conversation("trunk", "feature/old").await;
    rig.mgr
        .conversations()
        .mark_sensitive(&sid, crate::conversations::now_ms());
    let ServerMsg::ConversationHistory { entries, .. } =
        rig.mgr.conversation_history_msg("r".into())
    else {
        panic!()
    };
    assert!(entries[0].sensitive);
    assert_eq!(entries[0].main_checkout.as_deref(), main.to_str());
    assert!(entries[0].project_path.is_none());
    assert!(entries[0].branch.is_none());
    // And the daemon resumes it there.
    let reply = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&main));
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
}

#[tokio::test]
async fn a_main_checkout_that_is_not_a_git_checkout_is_refused() {
    let mut rig = Rig::new();
    let (sid, main, _wt) = rig.gone_worktree_conversation("trunk", "feature/old").await;
    // The folder is still there, but is a plain directory now.
    std::fs::remove_dir_all(main.join(".git")).unwrap();
    assert!(main.is_dir());
    let reply = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", place(&main));
    assert_eq!(outcome(&reply).2.as_deref(), Some("folder_gone"));
    assert!(!load_id_store(&rig.mgr.store_path).contains_key("cody-bbbb2222"));
}

// ── closing a focus is not "open elsewhere" ───────────────────────────────────

#[tokio::test]
async fn resuming_right_after_closing_a_focus_is_not_active_elsewhere_but_a_later_foreign_write_is()
{
    let mut rig = Rig::new();
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    let path = rig.transcript(&sid, USER_LINE);
    rig.wait_spawns(1).await;
    // The focus was closed: Nostromo stopped its session, whose last write was a moment ago.
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    let history = rig.mgr.conversations();
    assert!(history.stopped_at(&sid).is_some(), "the stop was noted");
    set_mtime(&path, std::time::SystemTime::now());
    let entry = history.get(&sid).unwrap();
    assert_eq!(
        list::status_now(&entry, &history, None),
        ConversationStatus::Available,
        "our own last write"
    );
    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(
        outcome(&reply).0,
        ConversationResumeOutcome::Ready,
        "no confirmation asked"
    );

    // A write well after our stop is someone else's.
    history.note_stopped(&sid, crate::conversations::now_ms() - 60_000);
    set_mtime(
        &path,
        std::time::SystemTime::now() - Duration::from_secs(10),
    );
    assert_eq!(
        list::status_now(&entry, &history, None),
        ConversationStatus::ActiveElsewhere
    );
}

// ── a focus with no codebase runs in a private folder ────────────────────────

fn no_codebase_focus(tag: &str) -> FocusMeta {
    let mut meta = test_focus(tag);
    meta.no_codebase = Some(true);
    meta
}

fn folder_resume(folder: &Path) -> ResumeOptions<'_> {
    ResumeOptions {
        no_codebase_folder: folder.to_str(),
        ..Default::default()
    }
}

impl Rig {
    /// Where no-codebase folders live in this rig.
    fn spaces(&self) -> PathBuf {
        self.dir.path().join("spaces")
    }

    /// A new empty folder directly under the spaces root.
    fn new_space(&self, name: &str) -> PathBuf {
        use std::hash::{Hash, Hasher};
        use std::os::unix::fs::PermissionsExt;
        // The daemon only resumes into a UUID-named, 0700 folder: derive a UUID from `name`.
        let mut h = std::collections::hash_map::DefaultHasher::new();
        name.hash(&mut h);
        let uuid = uuid::Uuid::from_u64_pair(h.finish(), 0x5eed);
        let p = self.spaces().join(uuid.to_string());
        std::fs::create_dir_all(&p).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o700)).unwrap();
        p
    }

    /// Start `tag` the way the app does for a no-codebase focus: registered as
    /// one, with its own folder as the working directory.
    fn spawn_no_codebase(&mut self, tag: &str, folder: &Path) -> String {
        self.mgr.set_focus_registry(vec![no_codebase_focus(tag)]);
        self.mgr
            .spawn_session(
                tag.into(),
                "cody".into(),
                "View".into(),
                Some(folder.to_path_buf()),
                None,
                false,
            )
            .unwrap()
            .expect("a session id")
    }

    /// Wait until the stub has logged the directory of `n` spawns.
    async fn wait_cwds(&self, n: usize) -> Vec<PathBuf> {
        injected_tests::eventually("the stub's working directory", || {
            let l = self.cwd_lines();
            (l.len() >= n).then_some(l)
        })
        .await
    }

    /// A no-codebase conversation `cody-aaaa1111` that ran in a private folder
    /// that is gone now. Returns `(sid, the gone folder)`.
    async fn gone_no_codebase_conversation(&mut self) -> (String, PathBuf) {
        let folder = self.new_space("space-gone");
        self.cwd = folder.clone();
        let sid = self.spawn_no_codebase("cody-aaaa1111", &folder);
        self.send("cody-aaaa1111", "hello");
        self.transcript(&sid, USER_LINE);
        self.wait_spawns(1).await;
        self.mgr.stop_session("cody-aaaa1111");
        self.mgr.sessions.remove("cody-aaaa1111");
        self.mgr.set_focus_registry(vec![]);
        std::fs::remove_dir_all(&folder).unwrap();
        (sid, folder)
    }
}

/// The argument words of a spawn, with the ids and tags of the run taken out.
fn argv_shape(line: &str, ids: &[&str]) -> Vec<String> {
    let words: Vec<&str> = line.split_whitespace().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < words.len() {
        if (words[i] == "--session-id" || words[i] == "--resume") && ids.contains(&words[i + 1]) {
            i += 2;
            continue;
        }
        let mut w = words[i].to_owned();
        for id in ids {
            w = w.replace(id, "ID");
        }
        out.push(w);
        i += 1;
    }
    out
}

#[tokio::test]
async fn a_no_codebase_focus_starts_the_agent_as_a_repo_focus_is_started_but_in_its_own_folder() {
    let mut rig = Rig::new();
    let folder = rig.new_space("space-one");
    let nc_sid = rig.spawn_no_codebase("cody-nc000001", &folder);
    rig.wait_spawns(1).await;
    let repo_sid = rig.spawn("cody-rp000001", "cody");
    let lines = rig.wait_spawns(2).await;
    let cwds = rig.wait_cwds(2).await;

    let shape = |line: &str, tag: &str, sid: &str| -> Vec<String> { argv_shape(line, &[sid, tag]) };
    assert_eq!(
        shape(&lines[0], "cody-nc000001", &nc_sid),
        shape(&lines[1], "cody-rp000001", &repo_sid),
        "a no-codebase focus's agent gets no extra or missing arguments"
    );

    assert_eq!(cwds[0], folder.canonicalize().unwrap());
    assert_eq!(cwds[1], rig.cwd.canonicalize().unwrap());
    if let Some(home) = std::env::var_os("HOME").filter(|h| !h.is_empty()) {
        assert_ne!(
            Some(cwds[0].clone()),
            Path::new(&home).canonicalize().ok(),
            "never the home directory"
        );
    }
}

#[tokio::test]
async fn a_no_codebase_focus_is_restarted_in_its_own_folder_too() {
    let mut rig = Rig::new();
    let folder = rig.new_space("space-restart");
    rig.spawn_no_codebase("cody-nc000001", &folder);
    rig.wait_spawns(1).await;
    rig.mgr.stop_session("cody-nc000001");
    rig.mgr.sessions.remove("cody-nc000001");
    rig.spawn_no_codebase("cody-nc000001", &folder);
    let cwds = rig.wait_cwds(2).await;
    assert_eq!(cwds[1], folder.canonicalize().unwrap());
}

#[tokio::test]
async fn a_no_codebase_focus_marks_its_conversation_and_the_mark_stays() {
    let mut rig = Rig::new();
    let folder = rig.new_space("space-mark");
    let sid = rig.spawn_no_codebase("cody-nc000001", &folder);
    let repo_sid = rig.spawn("cody-rp000001", "cody");
    rig.send("cody-nc000001", "hello");
    rig.send("cody-rp000001", "hello");

    let entry = rig.mgr.conversations().get(&sid).unwrap();
    assert!(entry.no_codebase);
    assert_eq!(entry.project_path.as_deref(), folder.to_str());
    assert!(
        !rig.mgr.conversations().get(&repo_sid).unwrap().no_codebase,
        "a repo focus's conversation is not marked"
    );

    // The focus is described without the flag from now on (an older app, a
    // registry rebuilt): the conversation is still the folder's.
    rig.mgr
        .set_focus_registry(vec![test_focus("cody-nc000001")]);
    rig.send("cody-nc000001", "again");
    assert!(rig.mgr.conversations().get(&sid).unwrap().no_codebase);
}

#[tokio::test]
async fn a_conversation_started_before_its_focus_was_known_to_have_no_codebase_is_marked_on_the_next_message(
) {
    let mut rig = Rig::new();
    let folder = rig.new_space("space-late");
    let sid = rig
        .mgr
        .spawn_session(
            "cody-nc000001".into(),
            "cody".into(),
            "View".into(),
            Some(folder),
            None,
            false,
        )
        .unwrap()
        .unwrap();
    assert!(!rig.mgr.conversations().get(&sid).unwrap().no_codebase);
    rig.mgr
        .set_focus_registry(vec![no_codebase_focus("cody-nc000001")]);
    rig.send("cody-nc000001", "hello");
    assert!(rig.mgr.conversations().get(&sid).unwrap().no_codebase);
}

// ── resuming into a new no-codebase folder ───────────────────────────────────

#[tokio::test]
async fn a_no_codebase_conversation_whose_folder_is_gone_resumes_in_a_fresh_empty_folder() {
    let mut rig = Rig::new();
    let (sid, gone) = rig.gone_no_codebase_conversation().await;
    let entry = rig.mgr.conversations().get(&sid).unwrap();
    assert!(
        matches!(
            list::status_now(&entry, &rig.mgr.conversations(), None),
            ConversationStatus::FolderGone { .. }
        ),
        "the row says the folder is gone"
    );
    let fresh = rig.new_space("space-fresh");
    let before = rig.stdin_log();

    let reply = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", folder_resume(&fresh));
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    let ServerMsg::ConversationResumeResult { project_path, .. } = &reply else {
        panic!()
    };
    assert_eq!(project_path.as_deref(), fresh.to_str());
    let entry = rig.mgr.conversations().get(&sid).unwrap();
    assert_eq!(entry.project_path.as_deref(), fresh.to_str());
    assert!(entry.no_codebase);
    assert!(entry.main_checkout.is_none());

    // The app's focus still names the folder that is gone: the spawn goes to the new one.
    rig.mgr
        .set_focus_registry(vec![no_codebase_focus("cody-bbbb2222")]);
    rig.cwd = gone.clone();
    rig.spawn("cody-bbbb2222", "cody");
    let lines = rig.wait_spawns(2).await;
    let cwds = rig.wait_cwds(2).await;
    assert_eq!(cwds[1], fresh.canonicalize().unwrap());
    let argv = &lines[1];
    assert_eq!(
        argv.matches("--append-system-prompt").count(),
        1,
        "exactly one flag: {argv}"
    );
    assert!(argv.contains("no-codebase folder"), "{argv}");
    assert!(argv.contains(&format!("--resume {sid}")), "{argv}");

    // Nothing was typed into the conversation and nothing was put in the folder.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(rig.stdin_log(), before, "no user turn was written");
    assert!(
        std::fs::read_dir(&fresh).unwrap().next().is_none(),
        "the new folder is still empty"
    );
    assert!(rig.mgr.conversations().get(&sid).unwrap().no_codebase);
}

#[tokio::test]
async fn a_no_codebase_resume_that_never_opens_puts_the_old_folder_and_the_mark_back() {
    for via_release in [true, false] {
        let mut rig = Rig::new();
        let (sid, gone) = rig.gone_no_codebase_conversation().await;
        let fresh = rig.new_space("space-fresh");
        let reply = rig
            .mgr
            .resume_conversation_with(&sid, "cody-bbbb2222", folder_resume(&fresh));
        assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
        if via_release {
            rig.mgr.release_resumed_tag("cody-bbbb2222");
        } else {
            rig.spawn("cody-bbbb2222", "cody");
            rig.mgr.fail_resumed_tag("cody-bbbb2222");
        }
        let after = rig.mgr.conversations().get(&sid).unwrap();
        assert_eq!(after.project_path.as_deref(), gone.to_str());
        assert!(
            after.no_codebase,
            "release={via_release}: still a no-codebase conversation"
        );
        assert_eq!(after.tag, "cody-aaaa1111");
        assert!(rig.mgr.resume_place_for("cody-bbbb2222", &sid).is_none());
        // The row reads "folder gone" again and the folder can be offered again.
        assert!(matches!(
            list::status_now(&after, &rig.mgr.conversations(), None),
            ConversationStatus::FolderGone { .. }
        ));
        let again = rig
            .mgr
            .resume_conversation_with(&sid, "cody-cccc3333", folder_resume(&fresh));
        assert_eq!(outcome(&again).0, ConversationResumeOutcome::Ready);
    }
}

/// The earlier value of the flag comes back, not a fixed one: a conversation
/// that was not a no-codebase one before the move is not one after it is undone.
#[tokio::test]
async fn undoing_a_resume_into_a_no_codebase_folder_restores_the_flag_the_entry_had() {
    let mut rig = Rig::new();
    // An ordinary conversation, its folder gone, no main checkout.
    let sid = rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.wait_spawns(1).await;
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    std::fs::remove_dir_all(&rig.cwd).unwrap();
    let old = rig.mgr.conversations().get(&sid).unwrap();
    assert!(!old.no_codebase);
    let fresh = rig.new_space("space-fresh");

    let reply = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", folder_resume(&fresh));
    if outcome(&reply).0 != ConversationResumeOutcome::Ready {
        // The daemon holds that only a no-codebase conversation moves into a
        // no-codebase folder: there is nothing to undo.
        return;
    }
    rig.mgr.release_resumed_tag("cody-bbbb2222");
    let after = rig.mgr.conversations().get(&sid).unwrap();
    assert_eq!(after.project_path, old.project_path);
    assert!(!after.no_codebase);
}

#[tokio::test]
async fn a_folder_that_is_not_a_fresh_empty_child_of_the_spaces_root_is_never_resumed_into() {
    let mut rig = Rig::new();
    let (sid, gone) = rig.gone_no_codebase_conversation().await;
    let spawns = rig.argv_lines().len();

    let outside = rig.dir.path().join("elsewhere");
    std::fs::create_dir_all(&outside).unwrap();
    let non_empty = rig.new_space("space-used");
    std::fs::write(non_empty.join("notes.txt"), "keep").unwrap();
    let real = rig.new_space("space-real");
    let link = rig.spaces().join(uuid::Uuid::new_v4().to_string());
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let missing = rig.spaces().join(uuid::Uuid::new_v4().to_string());
    let nested = rig
        .new_space("group")
        .join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir_all(&nested).unwrap();
    let dotdot_name = uuid::Uuid::new_v4().to_string();
    let dotdot = rig.spaces().join("group").join("..").join(&dotdot_name);
    std::fs::create_dir_all(rig.spaces().join(&dotdot_name)).unwrap();
    let root_itself = rig.spaces();

    let cases: [(&str, &Path); 8] = [
        ("outside the root", &outside),
        ("not empty", &non_empty),
        ("a symlink to a real folder under the root", &link),
        ("does not exist", &missing),
        ("a grandchild of the root", &nested),
        ("reached through ..", &dotdot),
        ("the root itself", &root_itself),
        ("a file", &non_empty.join("notes.txt")),
    ];
    for (why, folder) in cases {
        let reply = rig
            .mgr
            .resume_conversation_with(&sid, "cody-bbbb2222", folder_resume(folder));
        assert_eq!(
            outcome(&reply).2.as_deref(),
            Some("folder_gone"),
            "{why} must be refused"
        );
        assert!(
            !load_id_store(&rig.mgr.store_path).contains_key("cody-bbbb2222"),
            "{why}: no tag was reserved"
        );
        assert!(rig.mgr.resume_place_for("cody-bbbb2222", &sid).is_none());
        let entry = rig.mgr.conversations().get(&sid).unwrap();
        assert_eq!(
            entry.project_path.as_deref(),
            gone.to_str(),
            "{why}: nothing moved"
        );
        assert_eq!(entry.tag, "cody-aaaa1111");
    }
    assert_eq!(rig.argv_lines().len(), spawns, "nothing was spawned");
    // Nothing was written anywhere it was pointed.
    assert_eq!(
        std::fs::read_dir(&real).unwrap().count(),
        0,
        "the folder behind the symlink is untouched"
    );
    assert_eq!(std::fs::read_dir(&non_empty).unwrap().count(), 1);
    assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 0);
    assert!(!missing.exists(), "a missing folder is not created");
    assert!(!rig.mgr.conversations().get(&sid).unwrap().tag.is_empty());
}

#[tokio::test]
async fn no_codebase_folder_is_ignored_for_a_conversation_whose_own_folder_still_exists() {
    let mut rig = Rig::new();
    let folder = rig.new_space("space-here");
    rig.cwd = folder.clone();
    let sid = rig.spawn_no_codebase("cody-aaaa1111", &folder);
    rig.send("cody-aaaa1111", "hello");
    let path = rig.transcript(&sid, USER_LINE);
    age(&path, 3600);
    rig.wait_spawns(1).await;
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    rig.mgr.set_focus_registry(vec![]);
    // The folder to resume in is a different empty one, offered anyway.
    std::fs::write(folder.join("work.txt"), "x").unwrap();
    let other = rig.new_space("space-other");

    let reply = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", folder_resume(&other));
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    let ServerMsg::ConversationResumeResult { project_path, .. } = &reply else {
        panic!()
    };
    assert_eq!(
        project_path.as_deref(),
        folder.to_str(),
        "it resumes where it was"
    );
    assert!(rig.mgr.resume_place_for("cody-bbbb2222", &sid).is_none());
    assert_eq!(std::fs::read_dir(&other).unwrap().count(), 0);
}

// ── which folders the history still names ────────────────────────────────────

fn referenced(rig: &mut Rig) -> Vec<String> {
    let ServerMsg::ConversationHistory {
        referenced_space_folders,
        ..
    } = rig.mgr.conversation_history_msg("r".into())
    else {
        panic!()
    };
    let mut out = referenced_space_folders;
    out.sort();
    out
}

#[tokio::test]
async fn the_history_names_every_folder_under_the_spaces_root_an_unpurged_entry_uses_and_no_other()
{
    use crate::conversations::store::SpawnNote;
    let mut rig = Rig::new();
    let history = rig.mgr.conversations();
    let now = crate::conversations::now_ms();
    let root = rig.spaces();
    let note = |sid: &str, cwd: &Path| {
        history.note_spawn(
            SpawnNote {
                tag: "t",
                sid,
                agent: "cody",
                cwd: Some(cwd),
                title: "T",
                label: None,
                model: None,
                no_codebase: true,
            },
            now,
        );
    };
    let shown = |sid: &str| {
        history.note_user_send(sid, "hello", false, false, now);
        history.turn_completed(sid, true, false, now);
    };
    // Visible.
    note("s-visible", &root.join("a-visible"));
    shown("s-visible");
    // Hidden: spawned, no message yet.
    note("s-hidden", &root.join("b-hidden"));
    // Soft-removed: still there until the sheet closes.
    note("s-removed", &root.join("c-removed"));
    shown("s-removed");
    history.remove("s-removed", now);
    // Sensitive: its path is withheld from the list, but its folder is in use.
    note("s-sensitive", &root.join("d-sensitive"));
    shown("s-sensitive");
    history.mark_sensitive("s-sensitive", now);
    // Not a direct child of the root.
    note("s-outside", &rig.cwd);
    shown("s-outside");
    // (Their parents exist: a no-codebase entry whose parent cannot be read is named as text, below.)
    std::fs::create_dir_all(root.join("group")).unwrap();
    std::fs::create_dir_all(rig.dir.path().join("spaces-sibling")).unwrap();
    note("s-nested", &root.join("group").join("nested"));
    shown("s-nested");
    note(
        "s-sibling",
        &rig.dir.path().join("spaces-sibling").join("x"),
    );
    shown("s-sibling");

    let canonical_root = std::fs::canonicalize(&root).unwrap();
    let path = |name: &str| canonical_root.join(name).to_string_lossy().into_owned();
    assert_eq!(
        referenced(&mut rig),
        vec![
            path("a-visible"),
            path("b-hidden"),
            path("c-removed"),
            path("d-sensitive")
        ]
    );

    // The sheet closes: the removed one is purged, and its folder is no longer named.
    history.purge_removed(now);
    assert_eq!(
        referenced(&mut rig),
        vec![path("a-visible"), path("b-hidden"), path("d-sensitive")]
    );
}

#[tokio::test]
async fn a_daemon_root_left_as_a_symlink_still_names_a_folder_stored_by_its_real_path() {
    use crate::conversations::store::SpawnNote;
    let mut rig = Rig::new();
    let real = std::fs::canonicalize(rig.spaces()).unwrap();
    let link = rig.dir.path().join("spaces-link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    // The daemon's root is spelled through the link; the history holds the real path.
    std::env::set_var(SPACES_ROOT_ENV, &link);
    let folder = rig.new_space("by-real-path");
    let folder = real.join(folder.file_name().unwrap());
    let history = rig.mgr.conversations();
    let now = crate::conversations::now_ms();
    history.note_spawn(
        SpawnNote {
            tag: "t",
            sid: "s-real",
            agent: "cody",
            cwd: Some(&folder),
            title: "T",
            label: None,
            model: None,
            no_codebase: true,
        },
        now,
    );
    assert_eq!(
        referenced(&mut rig),
        vec![folder.to_string_lossy().into_owned()]
    );
}

/// One no-codebase entry whose stored path runs through `link`, which `after` then removes or re-points.
fn history_with_entry_stored_through_a_link(
    rig: &mut Rig,
    after: impl FnOnce(&Path, &Path),
) -> (PathBuf, String) {
    use crate::conversations::store::SpawnNote;
    let real = std::fs::canonicalize(rig.spaces()).unwrap();
    let folder = rig.new_space("through-a-link");
    let leaf = folder.file_name().unwrap().to_owned();
    let link = rig.dir.path().join("a-link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let stored = link.join(&leaf);
    rig.mgr.conversations().note_spawn(
        SpawnNote {
            tag: "t",
            sid: "s-link",
            agent: "cody",
            cwd: Some(&stored),
            title: "T",
            label: None,
            model: None,
            no_codebase: true,
        },
        crate::conversations::now_ms(),
    );
    after(&link, &real);
    (real.join(leaf), stored.to_string_lossy().into_owned())
}

#[tokio::test]
async fn a_folder_stored_through_a_symlink_that_was_later_removed_is_still_named() {
    let mut rig = Rig::new();
    let (folder, stored) = history_with_entry_stored_through_a_link(&mut rig, |link, _| {
        std::fs::remove_file(link).unwrap()
    });
    assert!(folder.is_dir(), "the folder is still under the root");
    let named = referenced(&mut rig);
    // Its stored path is passed on as text, so the app cannot resolve it and declines to sweep...
    assert!(named.contains(&stored), "{named:?}");
    // ...and the root's own child of that name is protected on top.
    assert!(
        named.contains(&folder.to_string_lossy().into_owned()),
        "{named:?}"
    );
}

#[tokio::test]
async fn a_folder_stored_through_a_symlink_that_now_points_elsewhere_is_still_named() {
    let mut rig = Rig::new();
    let elsewhere = rig.dir.path().join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    let (folder, _stored) = history_with_entry_stored_through_a_link(&mut rig, |link, _| {
        std::fs::remove_file(link).unwrap();
        std::os::unix::fs::symlink(&elsewhere, link).unwrap();
    });
    assert!(folder.is_dir());
    assert_eq!(
        referenced(&mut rig),
        vec![folder.to_string_lossy().into_owned()]
    );
}

#[tokio::test]
async fn a_spawn_request_that_says_no_codebase_without_a_folder_is_refused_before_any_registry_push(
) {
    let mut rig = Rig::new();
    // The registry is empty: the app's push has not landed yet.
    let err = rig
        .mgr
        .spawn_session_requested(
            "cody-cccc3333".into(),
            "cody".into(),
            "View".into(),
            None,
            None,
            false,
            true,
        )
        .expect_err("the request itself says no-codebase");
    assert!(err.to_string().contains("folder"), "{err}");
    assert!(!rig.mgr.sessions.contains_key("cody-cccc3333"));
}

#[tokio::test]
async fn a_no_codebase_focus_without_a_working_directory_is_never_started() {
    let mut rig = Rig::new();
    rig.mgr
        .set_focus_registry(vec![no_codebase_focus("cody-aaaa1111")]);
    let err = rig
        .mgr
        .spawn_session(
            "cody-aaaa1111".into(),
            "cody".into(),
            "View".into(),
            None,
            None,
            false,
        )
        .expect_err("no folder, no start");
    assert!(err.to_string().contains("folder"), "{err}");
    assert!(!rig.mgr.sessions.contains_key("cody-aaaa1111"));
    // An ordinary focus with no directory still starts.
    rig.mgr
        .set_focus_registry(vec![test_focus("cody-bbbb2222")]);
    assert!(rig
        .mgr
        .spawn_session(
            "cody-bbbb2222".into(),
            "cody".into(),
            "View".into(),
            None,
            None,
            false
        )
        .is_ok());
}

#[tokio::test]
async fn the_history_names_no_folder_when_no_conversation_has_one_under_the_root() {
    let mut rig = Rig::new();
    rig.spawn("cody-aaaa1111", "cody");
    rig.send("cody-aaaa1111", "hello");
    assert!(referenced(&mut rig).is_empty());
}

#[tokio::test]
async fn the_history_says_which_spaces_root_it_means() {
    let mut rig = Rig::new();
    let ServerMsg::ConversationHistory { spaces_root, .. } =
        rig.mgr.conversation_history_msg("r".into())
    else {
        panic!()
    };
    let want = std::fs::canonicalize(rig.spaces()).unwrap();
    assert_eq!(spaces_root.as_deref(), want.to_str());
}

#[tokio::test]
async fn a_stray_spaces_root_variable_does_not_move_a_daemon_that_is_not_in_qa_mode() {
    let mut rig = Rig::new();
    std::env::remove_var("NOSTROMO_QA_DAEMON");
    let folder = rig.new_space("space-stray");
    assert!(
        !crate::conversations::usable_space_folder(folder.to_str().unwrap()),
        "the variable is ignored, so this is not under the root"
    );
    let ServerMsg::ConversationHistory { spaces_root, .. } =
        rig.mgr.conversation_history_msg("r".into())
    else {
        panic!()
    };
    assert_ne!(
        spaces_root.as_deref(),
        std::fs::canonicalize(rig.spaces()).unwrap().to_str()
    );
}

// ── how the list shows it ────────────────────────────────────────────────────

#[tokio::test]
async fn a_no_codebase_conversation_lists_as_no_codebase_and_a_sensitive_one_only_says_it_has_none()
{
    let mut rig = Rig::new();
    let folder = rig.new_space("space-listed");
    let nc = rig.spawn_no_codebase("cody-nc000001", &folder);
    let repo = rig.spawn("cody-rp000001", "cody");
    rig.send("cody-nc000001", "hello");
    rig.send("cody-rp000001", "hello");

    let entries = |rig: &mut Rig| {
        let ServerMsg::ConversationHistory { entries, .. } =
            rig.mgr.conversation_history_msg("r".into())
        else {
            panic!()
        };
        entries
    };
    let by_id = |entries: &[crate::ipc::protocol::ConversationEntryWire], id: &str| {
        entries.iter().find(|e| e.id == id).cloned().unwrap()
    };
    let listed = entries(&mut rig);
    let w = by_id(&listed, &nc);
    assert_eq!(w.project_name.as_deref(), Some("No codebase"));
    assert!(w.no_codebase);
    assert_eq!(w.project_path.as_deref(), folder.to_str());
    let r = by_id(&listed, &repo);
    assert!(!r.no_codebase);
    assert_eq!(
        r.project_name.as_deref(),
        Some("work"),
        "a repo keeps its folder's name"
    );

    rig.mgr
        .conversations()
        .mark_sensitive(&nc, crate::conversations::now_ms());
    let listed = entries(&mut rig);
    let w = by_id(&listed, &nc);
    assert!(w.sensitive);
    assert!(w.no_codebase, "carried: it is no content");
    assert!(w.project_name.is_none() && w.project_path.is_none());
    let json = serde_json::to_string(&w).unwrap();
    let name = folder.file_name().unwrap().to_str().unwrap();
    assert!(!json.contains(name), "{json}");
}

// ── the tracker board follows it ─────────────────────────────────────────────

/// A board opened by `cody-aaaa1111` working in `folder`, which is no git
/// checkout: the board falls back to `<folder>/.claude/wip/<topic>/index.md`.
fn no_codebase_tracker(
    rig: &Rig,
    folder: &Path,
) -> (Arc<crate::tracker::TrackerRegistry>, PathBuf) {
    use crate::tracker::registry::{OpenArgs, RegistryParts};
    let base = rig.dir.path().canonicalize().unwrap();
    let home = base.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let reg = Arc::new(crate::tracker::TrackerRegistry::new(
        RegistryParts::hermetic(
            base.join("tracker-state"),
            home,
            Arc::new(crate::tracker::FakeClock::at_secs(1_760_540_000)),
        ),
    ));
    let args = OpenArgs {
        topic: Some("work".into()),
        cwd: folder.to_path_buf(),
        ..Default::default()
    };
    let path = reg.open("cody-aaaa1111", "s", &args).unwrap().path;
    (reg, path)
}

#[tokio::test]
async fn a_no_codebase_focus_keeps_its_board_in_its_folder_and_a_resume_there_is_bound_to_it() {
    let mut rig = Rig::new();
    let folder = rig.new_space("space-board");
    rig.cwd = folder.clone();
    let (reg, board) = no_codebase_tracker(&rig, &folder);
    assert!(
        board.starts_with(folder.canonicalize().unwrap()),
        "the board lives under the focus's folder: {board:?}"
    );
    assert!(board.ends_with(".claude/wip/work/index.md"), "{board:?}");
    rig.mgr.configure_tracker_frame_provider(reg.clone());
    let sid = rig.spawn_no_codebase("cody-aaaa1111", &folder);
    rig.send("cody-aaaa1111", "hello");
    let path = rig.transcript(&sid, USER_LINE);
    age(&path, 3600);
    rig.wait_spawns(1).await;
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    rig.mgr.set_focus_registry(vec![]);
    assert_eq!(
        rig.mgr
            .conversations()
            .get(&sid)
            .unwrap()
            .tracker_board
            .as_deref(),
        board.to_str(),
        "each send records the bound board"
    );

    let reply = rig.mgr.resume_conversation(&sid, "cody-bbbb2222");
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    assert_eq!(
        reg.bound_path("cody-bbbb2222").as_deref(),
        Some(board.as_path()),
        "the resumed focus has its board back"
    );
}

#[tokio::test]
async fn a_resume_into_a_fresh_no_codebase_folder_binds_no_board_and_creates_none() {
    let mut rig = Rig::new();
    let old = rig.new_space("space-board");
    rig.cwd = old.clone();
    let (reg, board) = no_codebase_tracker(&rig, &old);
    rig.mgr.configure_tracker_frame_provider(reg.clone());
    let sid = rig.spawn_no_codebase("cody-aaaa1111", &old);
    rig.send("cody-aaaa1111", "hello");
    rig.transcript(&sid, USER_LINE);
    rig.wait_spawns(1).await;
    rig.mgr.stop_session("cody-aaaa1111");
    rig.mgr.sessions.remove("cody-aaaa1111");
    rig.mgr.set_focus_registry(vec![]);
    reg.unbind("cody-aaaa1111");
    std::fs::remove_dir_all(&old).unwrap();
    let fresh = rig.new_space("space-fresh");

    let reply = rig
        .mgr
        .resume_conversation_with(&sid, "cody-bbbb2222", folder_resume(&fresh));
    assert_eq!(outcome(&reply).0, ConversationResumeOutcome::Ready);
    assert!(reg.bound_path("cody-bbbb2222").is_none());
    assert!(!board.exists());
    assert_eq!(std::fs::read_dir(&fresh).unwrap().count(), 0);
}

// ═════════════════════════════════════════════════════════════════════════════
// Terminal conversations (session history 4): opt-in, labelled, resumable
// ═════════════════════════════════════════════════════════════════════════════

fn terminal_transcript(rig: &Rig, sid: &str, agent: Option<&str>, secs_ago: u64) -> PathBuf {
    let folder = rig.dir.path().join("projects").join("-term-folder");
    std::fs::create_dir_all(&folder).unwrap();
    let cwd = rig.cwd.to_string_lossy();
    let mut body = String::new();
    if let Some(a) = agent {
        body += &format!("{{\"type\":\"agent-name\",\"agentName\":\"{a}\"}}\n");
    }
    body += &format!(
        "{{\"type\":\"user\",\"entrypoint\":\"cli\",\"cwd\":{cwd:?},\"gitBranch\":\"main\",\
         \"message\":{{\"content\":\"tidy the readme\"}}}}\n"
    );
    let path = folder.join(format!("{sid}.jsonl"));
    std::fs::write(&path, body).unwrap();
    age(&path, secs_ago);
    path
}

/// Restores `NOSTROMO_CLAUDE_AGENTS_DIR` to what it was when dropped.
struct AgentsDirGuard(Option<std::ffi::OsString>);

impl Drop for AgentsDirGuard {
    fn drop(&mut self) {
        match self.0.take() {
            Some(v) => std::env::set_var(crate::conversations::outside::AGENTS_DIR_ENV, v),
            None => std::env::remove_var(crate::conversations::outside::AGENTS_DIR_ENV),
        }
    }
}

#[must_use]
fn agents_dir(rig: &Rig, names: &[&str]) -> AgentsDirGuard {
    let dir = rig.dir.path().join("agents");
    std::fs::create_dir_all(&dir).unwrap();
    for n in names {
        std::fs::write(dir.join(format!("{n}.md")), "x").unwrap();
    }
    let guard = AgentsDirGuard(std::env::var_os(
        crate::conversations::outside::AGENTS_DIR_ENV,
    ));
    std::env::set_var(crate::conversations::outside::AGENTS_DIR_ENV, &dir);
    guard
}

fn listing(rig: &mut Rig) -> (Vec<crate::ipc::protocol::ConversationEntryWire>, bool, bool) {
    let ServerMsg::ConversationHistory {
        entries,
        include_outside,
        outside_ready,
        ..
    } = rig.mgr.conversation_history_msg("r".into())
    else {
        panic!("not a history");
    };
    (entries, include_outside, outside_ready)
}

fn wait_outside_ready(rig: &mut Rig) {
    for _ in 0..250 {
        if listing(rig).2 {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("the terminal index never became ready");
}

#[tokio::test]
async fn terminal_rows_appear_only_while_the_switch_is_on_and_off_deletes_the_index() {
    let mut rig = Rig::new();
    terminal_transcript(&rig, "term-1", None, 3600);
    let (rows, on, _) = listing(&mut rig);
    assert!(!on && rows.is_empty(), "off by default: no terminal rows");

    rig.mgr.set_include_outside(true);
    wait_outside_ready(&mut rig);
    let (rows, on, _) = listing(&mut rig);
    assert!(on);
    let row = rows
        .iter()
        .find(|r| r.id == "term-1")
        .expect("a terminal row");
    assert_eq!(row.origin.as_deref(), Some("terminal"));
    let index_file =
        crate::conversations::outside::path_beside(&rig.dir.path().join("daemon-sessions.json"));
    assert!(index_file.exists());

    rig.mgr.set_include_outside(false);
    let (rows, on, _) = listing(&mut rig);
    assert!(!on && rows.is_empty());
    assert!(!index_file.exists(), "off deletes the index file");
}

#[tokio::test]
async fn a_terminal_conversation_with_no_usable_agent_asks_for_one_and_adopts_nothing_until_it_starts(
) {
    let mut rig = Rig::new();
    let _agents = agents_dir(&rig, &["cody"]);
    terminal_transcript(&rig, "term-2", Some("not-an-agent"), 3600);
    rig.mgr.set_include_outside(true);
    wait_outside_ready(&mut rig);

    let reply = rig.mgr.resume_conversation("term-2", "cody-cccc3333");
    assert_eq!(outcome(&reply).2.as_deref(), Some("needs_agent"));
    assert!(!rig.mgr.conversations().known_sids().contains("term-2"));

    let reply = rig.mgr.resume_conversation_with(
        "term-2",
        "cody-cccc3333",
        ResumeOptions {
            agent: Some("cody"),
            ..ResumeOptions::default()
        },
    );
    let (kind, tag, _) = outcome(&reply);
    assert_eq!(kind, ConversationResumeOutcome::Ready);
    assert_eq!(tag.as_deref(), Some("cody-cccc3333"));
    assert!(rig.mgr.conversations().known_sids().contains("term-2"));
    let (rows, _, _) = listing(&mut rig);
    assert_eq!(rows.iter().filter(|r| r.id == "term-2").count(), 1);
    assert!(
        rows.iter()
            .find(|r| r.id == "term-2")
            .unwrap()
            .origin
            .is_none(),
        "now a Nostromo conversation"
    );
}

#[tokio::test]
async fn a_terminal_conversation_written_to_a_moment_ago_is_refused_and_stays_a_terminal_row() {
    let mut rig = Rig::new();
    let _agents = agents_dir(&rig, &["cody"]);
    terminal_transcript(&rig, "term-3", Some("cody"), 10);
    rig.mgr.set_include_outside(true);
    wait_outside_ready(&mut rig);
    let reply = rig.mgr.resume_conversation("term-3", "cody-dddd4444");
    assert_eq!(outcome(&reply).2.as_deref(), Some("active_elsewhere"));
    assert!(!rig.mgr.conversations().known_sids().contains("term-3"));
    let confirmed = rig.mgr.resume_conversation_with(
        "term-3",
        "cody-dddd4444",
        ResumeOptions {
            confirm_active_elsewhere: true,
            ..ResumeOptions::default()
        },
    );
    assert_eq!(
        outcome(&confirmed).0,
        ConversationResumeOutcome::Ready,
        "the recorded agent exists: none asked"
    );
}

#[tokio::test]
async fn with_the_switch_off_a_terminal_conversation_cannot_be_resumed() {
    let mut rig = Rig::new();
    let _agents = agents_dir(&rig, &["cody"]);
    terminal_transcript(&rig, "term-4", Some("cody"), 3600);
    let reply = rig.mgr.resume_conversation("term-4", "cody-eeee5555");
    assert_eq!(outcome(&reply).2.as_deref(), Some("not_found"));
}

#[tokio::test]
async fn a_terminal_conversation_cannot_be_resumed_once_the_switch_is_turned_off_again() {
    let mut rig = Rig::new();
    let _agents = agents_dir(&rig, &["cody"]);
    terminal_transcript(&rig, "term-5", Some("cody"), 3600);
    rig.mgr.set_include_outside(true);
    wait_outside_ready(&mut rig);
    // Turned off, but the index still holds the entry: only the resume's own
    // switch check refuses it.
    rig.mgr
        .conversations()
        .set_include_outside(false, crate::conversations::now_ms());
    assert!(rig.mgr.outside.get("term-5").is_some());
    let reply = rig.mgr.resume_conversation("term-5", "cody-ffff6666");
    assert_eq!(outcome(&reply).2.as_deref(), Some("not_found"));
    assert!(!rig.mgr.conversations().known_sids().contains("term-5"));
}

#[tokio::test]
async fn a_row_is_withheld_when_the_sensitive_registry_changes_after_it_was_indexed() {
    let mut rig = Rig::new();
    terminal_transcript(&rig, "term-6", None, 3600);
    rig.mgr.set_include_outside(true);
    wait_outside_ready(&mut rig);
    let shown = |rows: &[crate::ipc::protocol::ConversationEntryWire]| {
        rows.iter().find(|r| r.id == "term-6").unwrap().clone()
    };
    let (rows, _, _) = listing(&mut rig);
    assert_eq!(
        shown(&rows).first_prompt.as_deref(),
        Some("tidy the readme")
    );
    assert!(!shown(&rows).sensitive);
    // An unreadable registry makes `tag_is_sensitive("")` true: withhold.
    let _hold = rig.mgr.sensitive.hold_sensitive("");
    let (rows, _, _) = listing(&mut rig);
    let row = shown(&rows);
    assert!(row.sensitive && row.branch.is_none());
    assert!(
        row.first_prompt.is_none(),
        "no prompt text for a sensitive row"
    );
}

#[tokio::test]
async fn a_rescan_that_finds_nothing_new_does_not_bump_the_revision() {
    let mut rig = Rig::new();
    terminal_transcript(&rig, "term-7", None, 3600);
    rig.mgr.set_include_outside(true);
    wait_outside_ready(&mut rig);
    // The first scan's touch may land just after ready; let it settle.
    std::thread::sleep(Duration::from_millis(200));
    let revision = rig.mgr.conversations().revision();
    for _ in 0..3 {
        rig.mgr.conv.outside_scanned_at = None;
        listing(&mut rig);
        std::thread::sleep(Duration::from_millis(300));
    }
    assert_eq!(rig.mgr.conversations().revision(), revision);
    // A new terminal conversation does bump it.
    terminal_transcript(&rig, "term-8", None, 3000);
    rig.mgr.conv.outside_scanned_at = None;
    listing(&mut rig);
    for _ in 0..100 {
        if rig.mgr.conversations().revision() != revision {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("a changed list did not bump the revision");
}

// ── the queue: who the first prompt comes from when a queued message leaves ───

mod queue_candidates {
    use super::*;
    use crate::ipc::protocol::{ClaudeLoginPhase, QueueResultCode};
    use crate::ipc::session_manager::QueueVerb;

    const TAG: &str = "cody-aaaa1111";

    /// A session whose turn is running (no message of ours started it), so
    /// every send queues and none is a candidate by having been written.
    fn busy(rig: &mut Rig) -> String {
        let sid = rig.spawn(TAG, "cody");
        *lock_recover(&rig.mgr.sessions[TAG].shared.state) = SessionState::MidTurn;
        sid
    }

    fn turn_ends(rig: &Rig) {
        advance(&rig.mgr.sessions[TAG].shared);
    }

    fn first_prompt(rig: &Rig, sid: &str) -> FirstPrompt {
        rig.mgr.conversations().get(sid).unwrap().first_prompt
    }

    fn idle(rig: &Rig) {
        *lock_recover(&rig.mgr.sessions[TAG].shared.state) = SessionState::Idle;
    }

    fn typed(rig: &mut Rig, text: &str) -> String {
        rig.mgr.send_typed_message(TAG, text, &[], None).unwrap()
    }

    #[tokio::test]
    async fn taking_back_the_candidate_hands_candidacy_to_the_next_queued_message() {
        let mut rig = Rig::new();
        let sid = busy(&mut rig);
        let a = typed(&mut rig, "AAAWORDS");
        typed(&mut rig, "BBBWORDS");
        let answer = rig.mgr.queue_verb(TAG, &a, QueueVerb::TakeBack);
        assert_eq!(answer.code, QueueResultCode::TakenBack);
        turn_ends(&rig);
        rig.deliver(TAG);
        assert_eq!(
            first_prompt(&rig, &sid),
            FirstPrompt::Text("BBBWORDS".into())
        );
        assert!(!history_file(&rig).contains("AAAWORDS"));
    }

    #[tokio::test]
    async fn removing_the_candidate_hands_candidacy_on_too() {
        let mut rig = Rig::new();
        let sid = busy(&mut rig);
        let a = typed(&mut rig, "AAAWORDS");
        typed(&mut rig, "BBBWORDS");
        assert_eq!(
            rig.mgr.queue_verb(TAG, &a, QueueVerb::Remove).code,
            QueueResultCode::Removed
        );
        turn_ends(&rig);
        rig.deliver(TAG);
        assert_eq!(
            first_prompt(&rig, &sid),
            FirstPrompt::Text("BBBWORDS".into())
        );
    }

    #[tokio::test]
    async fn a_message_taken_back_behind_the_candidate_changes_nothing() {
        let mut rig = Rig::new();
        let sid = busy(&mut rig);
        typed(&mut rig, "AAAWORDS");
        let b = typed(&mut rig, "BBBWORDS");
        rig.mgr.queue_verb(TAG, &b, QueueVerb::TakeBack);
        turn_ends(&rig);
        rig.deliver(TAG);
        assert_eq!(
            first_prompt(&rig, &sid),
            FirstPrompt::Text("AAAWORDS".into())
        );
    }

    #[tokio::test]
    async fn taking_back_the_only_candidate_leaves_none_and_the_next_message_becomes_it() {
        let mut rig = Rig::new();
        let sid = busy(&mut rig);
        let a = typed(&mut rig, "AAAWORDS");
        rig.mgr.queue_verb(TAG, &a, QueueVerb::TakeBack);
        idle(&rig);
        rig.send(TAG, "SECONDWORDS");
        assert_eq!(
            first_prompt(&rig, &sid),
            FirstPrompt::Text("SECONDWORDS".into())
        );
        assert!(!history_file(&rig).contains("AAAWORDS"));
    }

    #[tokio::test]
    async fn removing_the_only_candidate_leaves_none_and_the_next_message_becomes_it() {
        let mut rig = Rig::new();
        let sid = busy(&mut rig);
        let a = typed(&mut rig, "AAAWORDS");
        rig.mgr.queue_verb(TAG, &a, QueueVerb::Remove);
        idle(&rig);
        rig.send(TAG, "SECONDWORDS");
        assert_eq!(
            first_prompt(&rig, &sid),
            FirstPrompt::Text("SECONDWORDS".into())
        );
    }

    #[tokio::test]
    async fn stop_dropping_the_only_candidate_leaves_none_and_the_next_message_becomes_it() {
        let mut rig = Rig::new();
        let sid = busy(&mut rig);
        typed(&mut rig, "AAAWORDS");
        let (outcome, dropped) = rig.mgr.interrupt_returning(TAG);
        assert!(outcome.is_ok());
        assert_eq!(dropped.typed.len(), 1);
        idle(&rig);
        rig.send(TAG, "SECONDWORDS");
        assert_eq!(
            first_prompt(&rig, &sid),
            FirstPrompt::Text("SECONDWORDS".into())
        );
        assert!(!history_file(&rig).contains("AAAWORDS"));
    }

    #[tokio::test]
    async fn a_delivered_candidate_keeps_todays_behaviour() {
        let mut rig = Rig::new();
        let sid = rig.spawn(TAG, "cody");
        let a = typed(&mut rig, "AAAWORDS");
        typed(&mut rig, "BBBWORDS");
        // `a` was written at once; taking `b` back changes nothing about `a`.
        let ids = lock_recover(&rig.mgr.sessions[TAG].shared.pending)
            .iter()
            .map(|m| m.id.clone())
            .collect::<Vec<_>>();
        rig.mgr.queue_verb(TAG, &ids[0], QueueVerb::TakeBack);
        assert_eq!(
            rig.mgr.queue_verb(TAG, &a, QueueVerb::TakeBack).code,
            QueueResultCode::AlreadyDelivered
        );
        rig.deliver(TAG);
        assert_eq!(
            first_prompt(&rig, &sid),
            FirstPrompt::Text("AAAWORDS".into())
        );
    }

    fn login_phase(rig: &Rig) -> (ClaudeLoginPhase, Option<String>) {
        match rig.mgr.login_snapshot() {
            ServerMsg::ClaudeLoginState { sessions, .. } => {
                let s = sessions.into_iter().find(|s| s.tag == TAG).expect("paused");
                (s.phase, s.hold_id)
            }
            other => panic!("{other:?}"),
        }
    }

    async fn stdin_has(rig: &Rig, needle: &str) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !rig.stdin_log().contains(needle) {
            assert!(Instant::now() < deadline, "the child never read {needle}");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    #[tokio::test]
    async fn take_back_of_the_held_message_returns_what_was_typed_and_pauses_with_nothing_to_resend(
    ) {
        let mut rig = Rig::new();
        let sid = rig.spawn(TAG, "cody");
        // The model note goes in front of the frame that is written (and held).
        *lock_recover(&rig.mgr.sessions[TAG].shared.note_prefix) = Some("NOTEWORDS".into());
        let hold = hold_first_message(&mut rig, TAG, "HELDWORDS please");
        stdin_has(&rig, "NOTEWORDS").await;
        let behind = typed(&mut rig, "BEHINDWORDS");

        let snap = rig.mgr.sessions[TAG].shared.queue_view().current();
        let held = snap.held.clone().expect("the held message is in the view");
        assert_eq!(held.hold_id, hold);
        assert!(held.can_take_back);
        assert_eq!(snap.entries.len(), 1, "queued behind the hold, visible");
        assert_eq!(snap.entries[0].id, behind);

        let answer = rig.mgr.queue_verb(TAG, &held.id, QueueVerb::TakeBack);

        assert_eq!(answer.code, QueueResultCode::TakenBack);
        assert_eq!(answer.text.as_deref(), Some("HELDWORDS please"));
        assert_eq!(login_phase(&rig), (ClaudeLoginPhase::PausedNoHold, None));
        assert!(rig.mgr.sessions[TAG]
            .shared
            .queue_view()
            .current()
            .held
            .is_none());
        // Nothing is ever written for it, and the queue behind stays put.
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(rig.stdin_log().matches("HELDWORDS").count(), 1);
        assert!(!rig.stdin_log().contains("BEHINDWORDS"));
        // The entry behind the hold is still take-back-able.
        assert_eq!(
            rig.mgr.queue_verb(TAG, &behind, QueueVerb::TakeBack).code,
            QueueResultCode::TakenBack
        );
        // What is typed next may open the conversation.
        idle(&rig);
        *lock_recover(&rig.mgr.sessions[TAG].shared.note_prefix) = None;
        assert!(
            rig.mgr.discard_held(TAG, None),
            "the pause can still be released"
        );
        rig.send(TAG, "SECONDWORDS");
        assert_eq!(
            first_prompt(&rig, &sid),
            FirstPrompt::Text("SECONDWORDS".into())
        );
    }

    #[tokio::test]
    async fn remove_of_the_held_message_discards_it_like_discard_held_and_the_queue_goes_on() {
        let mut rig = Rig::new();
        let sid = rig.spawn(TAG, "cody");
        hold_first_message(&mut rig, TAG, "HELDWORDS please");
        typed(&mut rig, "BEHINDWORDS");
        let held = rig.mgr.sessions[TAG]
            .shared
            .queue_view()
            .current()
            .held
            .unwrap();
        idle(&rig);

        let answer = rig.mgr.queue_verb(TAG, &held.id, QueueVerb::Remove);

        assert_eq!(answer.code, QueueResultCode::Removed);
        assert!(answer.text.is_none());
        assert!(!rig.mgr.has_login_hold(), "no hold, no pause");
        stdin_has(&rig, "BEHINDWORDS").await;
        assert_eq!(rig.stdin_log().matches("HELDWORDS").count(), 1);
        rig.deliver(TAG);
        // As for `discard_held` today: what was queued behind a held first
        // message is never a first prompt.
        assert_eq!(first_prompt(&rig, &sid), FirstPrompt::None);
        assert_eq!(
            rig.mgr.queue_verb(TAG, &held.id, QueueVerb::Remove).code,
            QueueResultCode::AlreadyDelivered,
            "a repeat names an id that was written once"
        );
    }

    #[tokio::test]
    async fn stop_returns_the_held_message_first_with_its_original_text() {
        let mut rig = Rig::new();
        rig.spawn(TAG, "cody");
        *lock_recover(&rig.mgr.sessions[TAG].shared.note_prefix) = Some("NOTEWORDS".into());
        hold_first_message(&mut rig, TAG, "HELDWORDS please");
        typed(&mut rig, "BEHINDWORDS");
        idle(&rig);

        let (outcome, dropped) = rig.mgr.interrupt_returning(TAG);

        assert!(
            matches!(outcome, Ok(InterruptOutcome::DiscardedHold)),
            "{outcome:?}"
        );
        let got: Vec<&str> = dropped.typed.iter().map(|e| e.text.as_str()).collect();
        assert_eq!(got, ["HELDWORDS please", "BEHINDWORDS"]);
    }
}
