//! The focus activity counters as a client sees them: `SessionManager::list()`
//! carries `agent_turns`, `agent_messages`, `agent_problems`, `activity_epoch`
//! and `last_problem` for every session, fed by real (stub) child processes.
//!
//! Contract under test (see `ipc::focus_activity`):
//!
//! * a turn the child completes adds one turn, its text records add messages,
//!   and a silent turn adds a `no_text` problem; the epoch never changes;
//! * a `result` with no turn open (a resume handshake) and a turn the operator
//!   interrupted count nothing;
//! * `restart` keeps the epoch and the counters and adds nothing;
//! * the operator's `stop` is a `stopped` problem; a crash the supervisor sees
//!   is a `crashed` problem, once; the crash-loop guard adds `crash_loop_guard`;
//!   a refused send is `send_refused`;
//! * another Claude session id for the focus is a new epoch at zero.
//!
//! Sessions are stub `sh -c` children whose stdout is read as stream-json, as in
//! `wake_tests.rs`. All text is fake.

use super::*;
use crate::ipc::focus_activity::ProblemKind;
use std::time::{Duration, Instant};

// ── rig ───────────────────────────────────────────────────────────────────────

fn tmp_store() -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!("nostromo-activity-test-{}.json", Uuid::new_v4()));
    p
}

/// A manager that kills every stub child when dropped, so a failing assertion
/// cannot leave a reader thread blocking the runtime's shutdown.
struct Mgr(SessionManager);

impl Mgr {
    fn new() -> Self {
        Mgr(SessionManager::with_store_path(tmp_store()))
    }
}

impl std::ops::Deref for Mgr {
    type Target = SessionManager;
    fn deref(&self) -> &SessionManager {
        &self.0
    }
}

impl std::ops::DerefMut for Mgr {
    fn deref_mut(&mut self) -> &mut SessionManager {
        &mut self.0
    }
}

impl Drop for Mgr {
    fn drop(&mut self) {
        self.0.kill_all_on_shutdown();
    }
}

/// A stub session `tag` on Claude session `sid`, running `script`.
fn spawn_as(mgr: &mut Mgr, tag: &str, sid: &str, resume: bool, script: &str) {
    let program = PathBuf::from("/bin/sh");
    let args = vec!["-c".to_string(), script.to_string()];
    let managed = mgr
        .spawn_managed(
            tag.to_string(),
            "agent".into(),
            "View".into(),
            None,
            false,
            sid.to_string(),
            resume,
            program.clone(),
            args.clone(),
            Some((program, args)),
        )
        .expect("spawn stub");
    mgr.sessions.insert(tag.to_string(), managed);
}

fn spawn_stub(mgr: &mut Mgr, tag: &str, script: &str) {
    spawn_as(mgr, tag, "stub-sid", false, script);
}

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

fn info(mgr: &Mgr, tag: &str) -> SessionInfo {
    mgr.list()
        .into_iter()
        .find(|i| i.tag == tag)
        .unwrap_or_else(|| panic!("{tag} is not listed"))
}

type Counts = (u64, u64, u64);

fn counts(mgr: &Mgr, tag: &str) -> Counts {
    let i = info(mgr, tag);
    (
        i.agent_turns.expect("agent_turns is always sent"),
        i.agent_messages.expect("agent_messages is always sent"),
        i.agent_problems.expect("agent_problems is always sent"),
    )
}

/// Wait for the listed counters to read `want`; on timeout say what they read.
async fn settle(mgr: &Mgr, tag: &str, want: Counts) -> SessionInfo {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if counts(mgr, tag) == want {
            return info(mgr, tag);
        }
        assert!(
            Instant::now() < deadline,
            "{tag}: counters (turns, messages, problems) are {:?}, wanted {want:?}",
            counts(mgr, tag)
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// The counters hold at `want` for a while (nothing late arrives).
async fn stays(mgr: &Mgr, tag: &str, want: Counts) {
    for _ in 0..8 {
        assert_eq!(counts(mgr, tag), want, "{tag}: counters moved");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn wait_exited(mgr: &Mgr, tag: &str) {
    eventually(&format!("{tag}'s child to exit"), || {
        mgr.sessions[tag]
            .shared
            .exited
            .load(Ordering::SeqCst)
            .then_some(())
    })
    .await;
}

async fn wait_idle(mgr: &Mgr, tag: &str) {
    eventually("the session to be idle", || {
        (mgr.session_state(tag) == Some(SessionState::Idle)).then_some(())
    })
    .await;
}

// ── stream lines (single-quote free: they go inside `sh -c` strings) ──────────

const ECHO: &str = r#"{"type":"user","isReplay":true,"message":{"role":"user","content":"hi"}}"#;
const TEXT: &str = r#"{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"ok"}]}}"#;
const TOOL: &str = r#"{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}"#;
const RESULT: &str = r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}"#;
const FAILED: &str = r#"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":1,"total_cost_usd":0.0,"result":"fake"}"#;

fn say(lines: &[&str]) -> String {
    lines
        .iter()
        .map(|l| format!("printf '%s\\n' '{l}'"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Answers every user frame it reads: the echo the CLI writes, a text reply, a
/// result.
const ANSWER_LOOP: &str = r#"while IFS= read -r line; do
  case "$line" in
    *'"type":"user"'*)
      printf '%s\n' "${line%\}},\"isReplay\":true}"
      printf '%s\n' '@TEXT@'
      printf '%s\n' '@RESULT@'
      ;;
  esac
done"#;

fn answer_loop() -> String {
    ANSWER_LOOP
        .replace("@TEXT@", TEXT)
        .replace("@RESULT@", RESULT)
}

// ── turns and messages ────────────────────────────────────────────────────────

#[tokio::test]
async fn a_completed_text_turn_counts_one_turn_and_one_message() {
    let mut mgr = Mgr::new();
    spawn_stub(
        &mut mgr,
        "t1",
        &format!("{}\ncat > /dev/null", say(&[ECHO, TEXT, RESULT])),
    );
    let epoch = info(&mgr, "t1")
        .activity_epoch
        .expect("an epoch from the start");

    let listed = settle(&mgr, "t1", (1, 1, 0)).await;

    assert_eq!(listed.last_problem, None);
    assert_eq!(
        listed.activity_epoch,
        Some(epoch),
        "the epoch never changes in a session"
    );
    mgr.stop("t1");
}

#[tokio::test]
async fn a_tool_only_turn_is_a_turn_with_a_no_text_problem() {
    let mut mgr = Mgr::new();
    spawn_stub(
        &mut mgr,
        "t2",
        &format!("{}\ncat > /dev/null", say(&[ECHO, TOOL, RESULT])),
    );

    let listed = settle(&mgr, "t2", (1, 0, 1)).await;

    assert_eq!(listed.last_problem, Some(ProblemKind::NoText));
    mgr.stop("t2");
}

#[tokio::test]
async fn an_error_result_is_a_turn_and_a_turn_error_problem() {
    let mut mgr = Mgr::new();
    spawn_stub(
        &mut mgr,
        "t3",
        &format!("{}\ncat > /dev/null", say(&[ECHO, TEXT, FAILED])),
    );

    let listed = settle(&mgr, "t3", (1, 1, 1)).await;

    assert_eq!(listed.last_problem, Some(ProblemKind::TurnError));
    mgr.stop("t3");
}

#[tokio::test]
async fn a_message_sent_through_the_manager_and_answered_is_one_turn_and_no_problem() {
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "t4", &answer_loop());

    mgr.send_user_message("t4", "fake question", &[]).unwrap();
    let listed = settle(&mgr, "t4", (1, 1, 0)).await;
    assert_eq!(listed.last_problem, None);

    mgr.send_user_message("t4", "another fake question", &[])
        .unwrap();
    settle(&mgr, "t4", (2, 2, 0)).await;
    mgr.stop("t4");
}

// ── nothing for a handshake, a replay or an interrupt ─────────────────────────

#[tokio::test]
async fn a_result_with_no_turn_open_is_not_a_turn() {
    let mut mgr = Mgr::new();
    // The resume handshake: a lone result, then the session works as usual.
    let script = format!("{}\n{}", say(&[RESULT]), answer_loop());
    spawn_as(&mut mgr, "hs", "stub-sid", true, &script);

    // Prove the handshake line was read: the next real turn is the first turn.
    mgr.send_user_message("hs", "fake question", &[]).unwrap();
    settle(&mgr, "hs", (1, 1, 0)).await;
    mgr.stop("hs");
}

#[tokio::test]
async fn a_resumed_session_with_no_history_starts_at_zero() {
    let mut mgr = Mgr::new();
    spawn_as(&mut mgr, "rs", "stub-sid", true, "cat > /dev/null");

    stays(&mgr, "rs", (0, 0, 0)).await;
    let listed = info(&mgr, "rs");
    assert_eq!(listed.last_problem, None);
    assert!(listed.activity_epoch.is_some());
    mgr.stop("rs");
}

#[tokio::test]
async fn a_turn_the_operator_interrupted_is_neither_a_turn_nor_a_problem() {
    let mut mgr = Mgr::new();
    let script = format!(
        r#"IFS= read -r line
printf '%s\n' "${{line%\}}}},\"isReplay\":true}}"
{tool}
while IFS= read -r line; do
  case "$line" in *'"subtype":"interrupt"'*) break ;; esac
done
{failed}
{answers}"#,
        tool = say(&[TOOL]),
        failed = say(&[FAILED]),
        answers = answer_loop(),
    );
    spawn_stub(&mut mgr, "ir", &script);

    mgr.send_user_message("ir", "fake long job", &[]).unwrap();
    eventually("the turn to be running", || {
        (mgr.session_state("ir") == Some(SessionState::MidTurn)).then_some(())
    })
    .await;
    assert_eq!(mgr.interrupt("ir").unwrap(), InterruptOutcome::Requested);
    wait_idle(&mgr, "ir").await;

    // The next real turn is the first one counted: had the interrupted turn
    // counted, this would read (2, 1, 1).
    mgr.send_user_message("ir", "fake follow-up", &[]).unwrap();
    let listed = settle(&mgr, "ir", (1, 1, 0)).await;
    assert_eq!(listed.last_problem, None);
    mgr.stop("ir");
}

// ── restart, stop, new session ────────────────────────────────────────────────

#[tokio::test]
async fn a_restart_keeps_the_epoch_and_the_counters_and_adds_nothing() {
    let mut mgr = Mgr::new();
    let marker = tmp_store().with_extension("ran");
    // First process: one text turn. Its replacement: the resume handshake (a
    // lone result), then it answers what it is sent.
    let script = format!(
        "if [ -e '{m}' ]; then\n{handshake}\nelse\n: > '{m}'\n{turn}\nfi\n{answers}",
        m = marker.display(),
        handshake = say(&[RESULT]),
        turn = say(&[ECHO, TEXT, RESULT]),
        answers = answer_loop(),
    );
    spawn_stub(&mut mgr, "rr", &script);
    let before = settle(&mgr, "rr", (1, 1, 0)).await;

    mgr.restart("rr").unwrap();

    let during = info(&mgr, "rr");
    assert_eq!(
        during.activity_epoch, before.activity_epoch,
        "same Claude session, same epoch"
    );
    // The new process's first turn is the second one counted, and the restart
    // itself (its internal stop, its handshake) added no turn, message or problem.
    mgr.send_user_message("rr", "fake question", &[]).unwrap();
    let after = settle(&mgr, "rr", (2, 2, 0)).await;
    assert_eq!(after.activity_epoch, before.activity_epoch);
    assert_eq!(after.last_problem, None);
    mgr.stop("rr");
    let _ = std::fs::remove_file(&marker);
}

#[tokio::test]
async fn the_operators_stop_is_a_stopped_problem() {
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "st", "cat > /dev/null");
    let epoch = info(&mgr, "st").activity_epoch;
    assert_eq!(counts(&mgr, "st"), (0, 0, 0));

    mgr.stop("st");

    let listed = settle(&mgr, "st", (0, 0, 1)).await;
    assert_eq!(listed.last_problem, Some(ProblemKind::Stopped));
    assert_eq!(listed.activity_epoch, epoch);
}

#[tokio::test]
async fn new_session_is_not_a_stopped_problem_and_the_next_spawn_is_a_new_epoch_at_zero() {
    let mut mgr = Mgr::new();
    spawn_as(
        &mut mgr,
        "ns",
        "sid-old",
        false,
        &format!("{}\ncat > /dev/null", say(&[ECHO, TEXT, RESULT])),
    );
    let old = settle(&mgr, "ns", (1, 1, 0)).await;

    mgr.new_session("ns");
    // "New session" is not the operator stopping the focus.
    let old_book = mgr.activity.for_session("ns", "sid-old").snapshot();
    assert_eq!(
        old_book.agent_problems, 0,
        "new_session must not count Stopped"
    );
    assert_eq!(old_book.epoch, old.activity_epoch.clone().unwrap());

    // The fresh conversation the supervisor or the operator starts next has
    // another Claude session id.
    spawn_as(&mut mgr, "ns", "sid-new", false, "cat > /dev/null");
    let fresh = info(&mgr, "ns");

    assert_ne!(
        fresh.activity_epoch, old.activity_epoch,
        "a new conversation is a new epoch"
    );
    assert_eq!(counts(&mgr, "ns"), (0, 0, 0));
    assert_eq!(fresh.last_problem, None);
    mgr.stop("ns");
}

#[tokio::test]
async fn two_focuses_count_independently() {
    let mut mgr = Mgr::new();
    spawn_as(
        &mut mgr,
        "ia",
        "sid-a",
        false,
        &format!("{}\ncat > /dev/null", say(&[ECHO, TEXT, RESULT])),
    );
    spawn_as(&mut mgr, "ib", "sid-b", false, "cat > /dev/null");

    settle(&mgr, "ia", (1, 1, 0)).await;
    stays(&mgr, "ib", (0, 0, 0)).await;
    assert_ne!(
        info(&mgr, "ia").activity_epoch,
        info(&mgr, "ib").activity_epoch
    );
    mgr.stop("ia");
    mgr.stop("ib");
}

// ── crashes and refused sends ─────────────────────────────────────────────────

#[tokio::test]
async fn a_crash_the_supervisor_sees_is_one_crashed_problem_however_often_it_looks() {
    let mut mgr = Mgr::new();
    // Exits on its own, and nobody is attached: the supervisor leaves it down.
    spawn_stub(&mut mgr, "cr", "true");
    wait_exited(&mgr, "cr").await;

    mgr.reap_and_recover();
    let listed = settle(&mgr, "cr", (0, 0, 1)).await;
    assert_eq!(listed.last_problem, Some(ProblemKind::Crashed));

    // The same crash, seen on later ticks, is not a new one.
    mgr.reap_and_recover();
    mgr.reap_and_recover();
    stays(&mgr, "cr", (0, 0, 1)).await;
}

#[tokio::test]
async fn an_exit_the_operator_asked_for_is_not_a_crash() {
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "ok", "cat > /dev/null");
    mgr.stop("ok");
    wait_exited(&mgr, "ok").await;

    mgr.reap_and_recover();

    // One problem: the stop. The supervisor does not add a crash for it.
    let listed = settle(&mgr, "ok", (0, 0, 1)).await;
    assert_eq!(listed.last_problem, Some(ProblemKind::Stopped));
    stays(&mgr, "ok", (0, 0, 1)).await;
}

#[tokio::test]
async fn crashes_the_supervisor_recovers_from_are_crashes_and_the_guard_trip_is_one_more_problem() {
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "lp", "true");
    mgr.sessions
        .get_mut("lp")
        .unwrap()
        .attached_clients
        .insert("c1".into());
    let epoch = info(&mgr, "lp").activity_epoch;
    wait_exited(&mgr, "lp").await;

    // Crashes the supervisor recovers from: each is one crashed problem, and
    // its own restart is not the operator's stop nor a new epoch.
    for n in 1..MAX_RESTARTS {
        mgr.reap_and_recover();
        wait_exited(&mgr, "lp").await;
        let listed = settle(&mgr, "lp", (0, 0, u64::from(n))).await;
        assert_eq!(listed.last_problem, Some(ProblemKind::Crashed));
        assert_eq!(listed.activity_epoch, epoch);
    }

    // The crash that reaches the limit: a crash, and the guard giving up.
    mgr.reap_and_recover();
    let listed = settle(&mgr, "lp", (0, 0, u64::from(MAX_RESTARTS) + 1)).await;
    assert_eq!(listed.last_problem, Some(ProblemKind::CrashLoopGuard));
    assert_eq!(
        mgr.sessions["lp"].stop_reason,
        Some(StopReason::CrashLoopGuard)
    );
    assert_eq!(listed.activity_epoch, epoch);
}

#[tokio::test]
async fn a_message_to_a_session_whose_process_is_gone_is_refused_and_counted() {
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "sr", "true");
    wait_exited(&mgr, "sr").await;

    let refused = mgr.send_user_message("sr", "fake message", &[]);

    assert!(refused.is_err(), "a dead session refuses the message");
    let listed = settle(&mgr, "sr", (0, 0, 1)).await;
    assert_eq!(listed.last_problem, Some(ProblemKind::SendRefused));

    assert!(mgr
        .send_user_message("sr", "fake message again", &[])
        .is_err());
    settle(&mgr, "sr", (0, 0, 2)).await;
}
