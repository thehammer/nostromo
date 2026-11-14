//! A manual compaction in a live session (Claude Code 2.1.318), seen through a
//! real (stub) child process whose stdout is the captured stream, as in
//! `slash_command_tests.rs`.
//!
//! Contract under test: after `/compact` the CLI's compaction lines (status,
//! boundary, summary, `Compacted` stdout, a `num_turns: 0` result) leave the
//! session Idle, the transcript holds the summary marker then ONE complete
//! `/compact` record carrying the token figures, a message queued behind the
//! compaction is written and answered, and nothing counts as an agent turn or a
//! `NoText` problem. All text is fake.

use super::injected_tests::{eventually, spawn_stub, tmp_store, turns_of, wait_turns, ASSISTANT_LINE, RESULT_LINE};
use super::*;
use crate::ipc::stream_json::{CompactInfo, Turn, TurnBlock};
use std::time::Duration;

const LIVE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/ipc/testdata/stream_compact.jsonl"
));

/// What the CLI prints in answer to `/compact`: everything after the first
/// turn's result in the captured stream.
fn compaction_lines() -> Vec<&'static str> {
    LIVE.lines().skip(4).collect()
}

/// A stub CLI: on a frame holding `/compact` it prints the captured
/// compaction; any other frame is echoed (`isReplay`), answered and finished.
fn compact_stub(lines: &[&str]) -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("compact.jsonl");
    std::fs::write(&path, lines.join("\n") + "\n").unwrap();
    let path = path.display().to_string();
    let script = format!(
        "while IFS= read -r line; do\n  case \"$line\" in\n    *'/compact'*) cat '{path}' ;;\n    *'\"type\":\"user\"'*)\n      printf '%s\\n' \"${{line%\\}}}},\\\"isReplay\\\":true}}\"\n      printf '%s\\n' '{ASSISTANT_LINE}'\n      printf '%s\\n' '{RESULT_LINE}'\n      ;;\n  esac\ndone\n"
    );
    (dir, script)
}

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

async fn settled(mgr: &SessionManager, tag: &str, n: usize) -> Vec<Turn> {
    wait_turns(mgr, tag, n).await;
    eventually("the last turn complete and the session idle", || {
        (turns_of(mgr, tag).last().is_some_and(|t| t.is_complete)
            && mgr.session_state(tag) == Some(SessionState::Idle))
        .then_some(())
    })
    .await;
    tokio::time::sleep(Duration::from_millis(150)).await;
    turns_of(mgr, tag)
}

fn counts(mgr: &SessionManager, tag: &str) -> (u64, u64, u64) {
    let i = mgr
        .list()
        .into_iter()
        .find(|i| i.tag == tag)
        .expect("the session is listed");
    (
        i.agent_turns.expect("agent_turns is always sent"),
        i.agent_messages.expect("agent_messages is always sent"),
        i.agent_problems.expect("agent_problems is always sent"),
    )
}

fn texts(t: &Turn) -> Vec<&str> {
    t.blocks
        .iter()
        .filter_map(|b| match b {
            TurnBlock::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect()
}

fn is_summary_marker(t: &Turn) -> bool {
    matches!(&t.origin, Some(TurnOrigin::InjectedContext { kind, .. }) if kind == "summary")
}

fn assert_compact_record(t: &Turn, expected: CompactInfo) {
    assert_eq!(t.user_input, "/compact");
    assert!(t.is_complete);
    assert!(
        matches!(&t.origin, Some(TurnOrigin::LocalCommand { command, compact, .. })
            if command == "compact" && compact.as_ref() == Some(&expected)),
        "{t:?}"
    );
    assert!(texts(t).is_empty(), "the outcome is in the origin: {t:?}");
}

#[tokio::test]
async fn a_manual_compaction_leaves_a_summary_marker_and_one_compact_record_with_the_tokens_and_the_session_idle(
) {
    let (_dir, script) = compact_stub(&compaction_lines());
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "c", &script);

    mgr.send_user_message("c", "/compact", &[]).unwrap();
    let turns = settled(&mgr, "c", 2).await;

    assert_eq!(turns.len(), 2, "[summary marker, record]: {turns:?}");
    assert!(is_summary_marker(&turns[0]), "{:?}", turns[0]);
    assert!(turns[0].is_complete);
    assert_compact_record(
        &turns[1],
        CompactInfo {
            pre_tokens: Some(3429),
            post_tokens: Some(643),
            failed: false,
            error: None,
        },
    );
    assert_eq!(mgr.session_state("c"), Some(SessionState::Idle));
    mgr.stop("c");
}

#[tokio::test]
async fn a_compaction_is_no_prompt_no_agent_turn_and_no_problem() {
    let (_dir, script) = compact_stub(&compaction_lines());
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "np", &script);

    mgr.send_user_message("np", "/compact", &[]).unwrap();
    settled(&mgr, "np", 2).await;

    {
        let t = lock_recover(&mgr.sessions["np"].shared.transcript);
        assert_eq!(t.prompt_count(), 0);
        assert_eq!(t.first_user_input(), None);
    }
    assert_eq!(
        counts(&mgr, "np"),
        (0, 0, 0),
        "a compaction is not an agent turn and never a NoText problem"
    );
    mgr.stop("np");
}

#[tokio::test]
async fn a_message_queued_behind_a_compaction_is_written_and_answered_when_its_result_arrives() {
    let (_dir, script) = compact_stub(&compaction_lines());
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "q", &script);

    mgr.send_user_message("q", "/compact", &[]).unwrap();
    mgr.send_user_message("q", "after the compaction", &[]).unwrap();
    let turns = settled(&mgr, "q", 3).await;

    assert_eq!(turns.len(), 3, "{turns:?}");
    assert!(is_summary_marker(&turns[0]));
    assert_compact_record(
        &turns[1],
        CompactInfo {
            pre_tokens: Some(3429),
            post_tokens: Some(643),
            failed: false,
            error: None,
        },
    );
    assert_eq!(turns[2].user_input, "after the compaction");
    assert_eq!(turns[2].origin, None);
    assert!(turns[2].is_complete);
    assert_eq!(texts(&turns[2]), vec!["ok"]);
    assert!(turns.iter().all(|t| t.is_complete));
    {
        let t = lock_recover(&mgr.sessions["q"].shared.transcript);
        assert_eq!(t.prompt_count(), 1, "only the queued message is a prompt");
        assert_eq!(t.first_user_input(), Some("after the compaction"));
    }
    assert_eq!(counts(&mgr, "q"), (1, 1, 0));
    assert_eq!(mgr.session_state("q"), Some(SessionState::Idle));
    mgr.stop("q");
}
