//! The QA instance's `scripts/qa/fake-claude` wrapper (what the QA daemon gets as
//! `NOSTROMO_CLAUDE_BIN`) drives a real `SessionManager` session through the real
//! `stream_json` parser to a completed turn.

use std::time::{Duration, Instant};

use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::session_manager::{SessionManager, CLAUDE_BIN_ENV};
use nostromo::ipc::stream_json::{TurnBlock, TurnDelta};

#[test]
fn the_qa_fake_claude_wrapper_completes_a_plain_turn_through_the_daemon_parser() {
    let wrapper = concat!(env!("CARGO_MANIFEST_DIR"), "/scripts/qa/fake-claude");
    let tmp = tempfile::tempdir().unwrap();
    // The QA daemon runs with its own HOME and no FAKE_CLAUDE_LOG_DIR; the wrapper must cope.
    std::env::set_var("HOME", tmp.path());
    std::env::remove_var("FAKE_CLAUDE_LOG_DIR");
    std::env::set_var(CLAUDE_BIN_ENV, wrapper);
    let work = tmp.path().join("work");
    std::fs::create_dir_all(&work).unwrap();

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .unwrap();
    rt.block_on(async {
        let mut mgr = SessionManager::with_store_path(tmp.path().join("daemon-sessions.json"));
        mgr.spawn_session(
            "qa-1".into(),
            "cody".into(),
            "view-qa-1".into(),
            Some(work),
            None,
            false,
        )
        .expect("the fake CLI starts");
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<ServerMsg>();
        mgr.client_sender_registry()
            .lock()
            .unwrap()
            .insert("probe".into(), tx);
        mgr.attach("qa-1", "probe").unwrap();
        mgr.send_user_message("qa-1", "hello from the QA harness", &[])
            .expect("message accepted");

        let deadline = Instant::now() + Duration::from_secs(30);
        let mut saw_text = false;
        let mut completed = false;
        while !completed {
            if Instant::now() >= deadline {
                mgr.kill_all_on_shutdown();
                panic!("no completed turn from the fake CLI (saw text: {saw_text})");
            }
            while let Ok(msg) = rx.try_recv() {
                if let ServerMsg::SessionTurnDelta { delta, .. } = msg {
                    match delta {
                        TurnDelta::BlockAppended {
                            block: TurnBlock::Text { .. },
                            ..
                        } => saw_text = true,
                        TurnDelta::TurnCompleted { .. } => completed = true,
                        _ => {}
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(5));
            tokio::task::yield_now().await;
        }
        mgr.kill_all_on_shutdown();
        assert!(saw_text, "the completed turn carried assistant text");
    });
}
