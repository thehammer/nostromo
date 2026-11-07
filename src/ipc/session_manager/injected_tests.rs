//! Provenance of user-role turns at the session reader (`run_reader`).
//!
//! The live stdout stream carries no `promptSource`/`isMeta`/`turnOrigin`
//! (captured from `claude --input-format stream-json --replay-user-messages`:
//! an echo has only `isReplay: true`), so the daemon's `written` queue is the
//! sole live provenance:
//!
//! * a message the daemon wrote stays the user's turn, whatever its shape
//!   (skill, peer, summary): its text, prompt count and title intact;
//! * a turn the CLI began with an injected shape is a marker, and two peer
//!   messages with no reply between merge into one turn;
//! * a replayed line, or one the daemon wrote, is never adopted as `other`;
//! * a CLI-begun line of no known shape and not replayed is `other`.

use super::*;
use crate::ipc::stream_json::Turn;
use std::time::{Duration, Instant};

fn tmp_store() -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!("nostromo-injected-test-{}.json", Uuid::new_v4()));
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

const ASSISTANT_LINE: &str = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#;
const RESULT_LINE: &str = r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}"#;

/// Echoes each user frame as the CLI does (`isReplay`, no provenance fields), answers it.
fn echo_stub() -> String {
    format!(
        r#"while IFS= read -r line; do
  case "$line" in
    *'"type":"user"'*)
      printf '%s\n' "${{line%\}}}},\"isReplay\":true}}"
      printf '%s\n' '{ASSISTANT_LINE}'
      printf '%s\n' '{RESULT_LINE}'
      ;;
  esac
done"#
    )
}

fn user_line(content: &str, extra: serde_json::Value) -> String {
    let mut line =
        serde_json::json!({"type": "user", "message": {"role": "user", "content": content}});
    for (k, v) in extra.as_object().unwrap() {
        line[k] = v.clone();
    }
    line.to_string()
}

fn peer_text(body: &str) -> String {
    format!(
        "Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/x.sock\" from-name=\"Claudia\" from-mode=\"bypass\">\n{body}\n</cross-session-message>"
    )
}

fn turns_of(mgr: &SessionManager, tag: &str) -> Vec<Turn> {
    lock_recover(&mgr.sessions[tag].shared.transcript).snapshot()
}

async fn wait_turns(mgr: &SessionManager, tag: &str, n: usize) -> Vec<Turn> {
    eventually(&format!("{n} turns"), || {
        let t = turns_of(mgr, tag);
        (t.len() >= n).then_some(t)
    })
    .await
}

async fn wait_marker(mgr: &SessionManager, tag: &str) {
    eventually("an injected marker", || {
        matches!(
            turns_of(mgr, tag).first().and_then(|t| t.origin.as_ref()),
            Some(TurnOrigin::InjectedContext { .. })
        )
        .then_some(())
    })
    .await;
}

#[tokio::test]
async fn a_message_the_daemon_wrote_stays_a_user_turn_whatever_its_shape() {
    let shapes = [
        (
            "skill",
            "Base directory for this skill: /x/.claude/skills/demo\n\nbody".to_string(),
        ),
        ("peer", peer_text("quoted by the user")),
        (
            "summary",
            "This session is being continued from a previous conversation that ran out of context."
                .to_string(),
        ),
    ];
    for (name, text) in shapes {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        let tag = format!("w-{name}");
        spawn_stub(&mut mgr, &tag, &echo_stub());

        mgr.send_user_message(&tag, &text, &[]).unwrap();
        let turns = wait_turns(&mgr, &tag, 1).await;

        assert_eq!(turns[0].origin, None, "{name}");
        assert_eq!(turns[0].user_input, text, "{name}");
        let transcript = lock_recover(&mgr.sessions[&tag].shared.transcript);
        assert_eq!(transcript.prompt_count(), 1, "{name}");
        assert_eq!(transcript.first_user_input(), Some(text.as_str()), "{name}");
        drop(transcript);
        mgr.stop(&tag);
    }
}

#[tokio::test]
async fn a_peer_shaped_echo_after_an_open_peer_turn_is_never_folded_into_it() {
    // A CLI peer line opens a turn that no reply has touched; the next live
    // line is peer-shaped too. With no written message behind it, it is
    // judged by the reader as the CLI's: it merges. With the daemon's own
    // message behind it, it must stay a separate user turn.
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let peer = dir.path().join("peer.jsonl");
    std::fs::write(
        &peer,
        user_line(&peer_text("from the peer"), serde_json::json!({})) + "\n",
    )
    .unwrap();
    let go = dir.path().join("go");
    // The user's frame is read first and echoed AFTER the peer's turn opened.
    let script = format!(
        r#"IFS= read -r line
while [ ! -e '{go}' ]; do sleep 0.05; done
cat '{peer}'
printf '%s\n' "${{line%\}}}},\"isReplay\":true}}"
sleep 30"#,
        go = go.display(),
        peer = peer.display(),
    );
    spawn_stub(&mut mgr, "typed", &script);
    let typed = peer_text("typed by the human");

    mgr.send_user_message("typed", &typed, &[]).unwrap();
    std::fs::write(&go, b"go").unwrap();
    wait_turns(&mgr, "typed", 1).await;
    // Whichever line the reader bound the written message to, the human's
    // text never appears inside a peer marker's items.
    eventually("the typed text as a user turn", || {
        let turns = turns_of(&mgr, "typed");
        turns
            .iter()
            .any(|t| t.origin.is_none() && t.user_input.contains("typed by the human"))
            .then_some(())
    })
    .await;
    for t in turns_of(&mgr, "typed") {
        if let Some(TurnOrigin::PeerMessage { items, .. }) = &t.origin {
            assert!(
                items.iter().all(|i| !i.body.contains("typed by the human")),
                "typed text merged into a peer marker: {items:?}"
            );
        }
    }
    mgr.stop("typed");
}

#[tokio::test]
async fn a_peer_turn_the_cli_began_is_a_marker_and_a_second_one_merges_into_it() {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let lines = dir.path().join("peers.jsonl");
    std::fs::write(
        &lines,
        format!(
            "{}\n{}\n",
            user_line(&peer_text("one"), serde_json::json!({})),
            user_line(&peer_text("two"), serde_json::json!({}))
        ),
    )
    .unwrap();
    spawn_stub(
        &mut mgr,
        "p",
        &format!("cat '{}'; sleep 30", lines.display()),
    );

    let turns = eventually("both peer messages in one turn", || {
        let t = turns_of(&mgr, "p");
        match t.first().and_then(|t| t.origin.as_ref()) {
            Some(TurnOrigin::PeerMessage { items, .. }) if items.len() == 2 => Some(t),
            _ => None,
        }
    })
    .await;

    assert_eq!(turns.len(), 1);
    assert_eq!(
        lock_recover(&mgr.sessions["p"].shared.transcript).prompt_count(),
        0
    );
    mgr.stop("p");
}

#[tokio::test]
async fn a_cli_begun_line_of_no_known_shape_is_an_other_marker() {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("l.jsonl");
    std::fs::write(
        &f,
        user_line("Hook says: check the logs", serde_json::json!({})) + "\n",
    )
    .unwrap();
    spawn_stub(&mut mgr, "o", &format!("cat '{}'; sleep 30", f.display()));

    wait_marker(&mgr, "o").await;

    assert_eq!(turns_of(&mgr, "o")[0].user_input, "Injected context");
    let t = lock_recover(&mgr.sessions["o"].shared.transcript);
    assert_eq!((t.prompt_count(), t.first_user_input()), (0, None));
    drop(t);
    mgr.stop("o");
}

#[tokio::test]
async fn a_replayed_line_is_never_adopted_as_other() {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("l.jsonl");
    std::fs::write(
        &f,
        user_line(
            "echo of something the host wrote",
            serde_json::json!({"isReplay": true}),
        ) + "\n",
    )
    .unwrap();
    spawn_stub(&mut mgr, "r", &format!("cat '{}'; sleep 30", f.display()));

    let turns = wait_turns(&mgr, "r", 1).await;
    assert_eq!(turns[0].origin, None);
    assert_eq!(turns[0].user_input, "echo of something the host wrote");
    mgr.stop("r");
}

#[tokio::test]
async fn a_live_line_claiming_the_host_sent_it_gets_no_trust_from_the_claim() {
    // A live line's `promptSource` is not read: with no written message the
    // CLI began it, so unknown text is `other` even if it says "sdk".
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("l.jsonl");
    std::fs::write(
        &f,
        user_line("claims sdk", serde_json::json!({"promptSource": "sdk"})) + "\n",
    )
    .unwrap();
    spawn_stub(&mut mgr, "s", &format!("cat '{}'; sleep 30", f.display()));

    wait_marker(&mgr, "s").await;
    mgr.stop("s");
}

fn assert_other_marker_turn(t: &Turn) {
    assert!(
        matches!(t.origin, Some(TurnOrigin::InjectedContext { .. })),
        "expected an injected-context marker, got {t:?}"
    );
    assert_eq!(t.user_input, "Injected context");
}

#[tokio::test]
async fn a_cli_line_after_a_typed_slash_commands_harness_echo_is_a_marker_not_a_bubble() {
    // The human's `/cmd` is echoed only as a harness line (dropped by the
    // parser). A later CLI-started line of no known shape must not inherit the
    // human's message.
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("out.jsonl");
    let harness = serde_json::json!({
        "type": "user",
        "isReplay": true,
        "message": {"role": "user",
            "content": "<command-message>cmd</command-message>\n<command-name>/cmd</command-name>"}
    })
    .to_string();
    std::fs::write(
        &f,
        format!(
            "{harness}\n{ASSISTANT_LINE}\n{RESULT_LINE}\n{}\n",
            user_line("scheduled: check the build", serde_json::json!({}))
        ),
    )
    .unwrap();
    let script = format!("IFS= read -r line\ncat '{}'\nsleep 30", f.display());
    spawn_stub(&mut mgr, "cmd", &script);

    mgr.send_user_message("cmd", "/cmd", &[]).unwrap();
    let turns = eventually("a marker turn", || {
        let t = turns_of(&mgr, "cmd");
        t.iter()
            .any(|t| matches!(t.origin, Some(TurnOrigin::InjectedContext { .. })))
            .then_some(t)
    })
    .await;

    for t in &turns {
        assert_ne!(t.user_input, "scheduled: check the build");
        assert_ne!(
            t.user_input, "/cmd",
            "the CLI line took the human's message"
        );
    }
    assert_other_marker_turn(turns.last().unwrap());
    let t = lock_recover(&mgr.sessions["cmd"].shared.transcript);
    assert_eq!(t.prompt_count(), 0);
    assert_eq!(t.first_user_input(), None);
    drop(t);
    mgr.stop("cmd");
}

#[tokio::test]
async fn a_cli_line_between_the_write_and_its_echo_never_takes_the_humans_message() {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let cli = dir.path().join("cli.jsonl");
    std::fs::write(
        &cli,
        user_line("scheduled: check the build", serde_json::json!({})) + "\n",
    )
    .unwrap();
    let go = dir.path().join("go");
    let script = format!(
        r#"IFS= read -r line
while [ ! -e '{go}' ]; do sleep 0.05; done
cat '{cli}'
printf '%s\n' "${{line%\}}}},\"isReplay\":true}}"
sleep 30"#,
        go = go.display(),
        cli = cli.display(),
    );
    spawn_stub(&mut mgr, "between", &script);
    let typed = "please look at the retry path";

    mgr.send_user_message("between", typed, &[]).unwrap();
    std::fs::write(&go, b"go").unwrap();
    let turns = wait_turns(&mgr, "between", 2).await;

    assert_other_marker_turn(&turns[0]);
    assert_eq!(turns[1].origin, None);
    assert_eq!(turns[1].user_input, typed);
    let t = lock_recover(&mgr.sessions["between"].shared.transcript);
    assert_eq!(t.prompt_count(), 1);
    assert_eq!(t.first_user_input(), Some(typed));
    drop(t);
    mgr.stop("between");
}

#[tokio::test]
async fn a_replayed_line_of_peer_or_skill_shape_with_nothing_written_is_a_plain_bubble() {
    let shapes = [
        ("peer", peer_text("quoted by the human")),
        (
            "skill",
            "Base directory for this skill: /x/.claude/skills/demo\n\nbody".to_string(),
        ),
    ];
    for (name, text) in shapes {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("l.jsonl");
        std::fs::write(
            &f,
            user_line(&text, serde_json::json!({"isReplay": true})) + "\n",
        )
        .unwrap();
        let tag = format!("rp-{name}");
        spawn_stub(&mut mgr, &tag, &format!("cat '{}'; sleep 30", f.display()));

        let turns = wait_turns(&mgr, &tag, 1).await;

        assert_eq!(turns[0].origin, None, "{name}");
        assert_eq!(turns[0].user_input, text, "{name}");
        assert_eq!(
            lock_recover(&mgr.sessions[&tag].shared.transcript).prompt_count(),
            1,
            "{name}"
        );
        mgr.stop(&tag);
    }
}

#[tokio::test]
async fn a_replayed_peer_line_with_nothing_written_is_never_merged_into_an_open_cli_peer_turn() {
    let mut mgr = SessionManager::with_store_path(tmp_store());
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("l.jsonl");
    // The CLI's own peer turn opens, then an echo (`isReplay`) of peer shape
    // arrives with nothing in the daemon's written queue.
    std::fs::write(
        &f,
        user_line(&peer_text("from the peer"), serde_json::json!({}))
            + "\n"
            + &user_line(
                &peer_text("replayed human text"),
                serde_json::json!({"isReplay": true}),
            )
            + "\n",
    )
    .unwrap();
    spawn_stub(&mut mgr, "rm", &format!("cat '{}'; sleep 30", f.display()));

    let turns = wait_turns(&mgr, "rm", 2).await;

    assert!(matches!(turns[0].origin, Some(TurnOrigin::PeerMessage { .. })));
    if let Some(TurnOrigin::PeerMessage { items, .. }) = &turns[0].origin {
        assert_eq!(items.len(), 1, "the replayed line merged: {items:?}");
        assert!(items.iter().all(|i| !i.body.contains("replayed human text")));
    }
    assert_eq!(turns[1].origin, None);
    assert_eq!(turns[1].user_input, peer_text("replayed human text"));
    mgr.stop("rm");
}
