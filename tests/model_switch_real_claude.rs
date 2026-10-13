//! Live model switching against the REAL `claude` CLI (opt-in).
//!
//! `tests/model_switch.rs` proves the daemon's behaviour against a fake `claude`. This test proves
//! the fake is honest: that the real CLI really switches model mid-session, keeps the conversation,
//! rejects a bad model without hurting the session, and reports effort back through `get_settings`.
//!
//! Run it with
//!
//! ```text
//! NOSTROMO_REAL_CLAUDE=1 cargo test --test model_switch_real_claude -- --ignored --nocapture
//! ```
//!
//! It uses your real `claude` login (`~/.local/bin/claude`). Spend is capped: the session is started
//! through a wrapper that adds `--max-budget-usd 0.05`, no tools, project settings only and a
//! one-word system prompt; it runs Haiku and Sonnet for four short turns. It never runs by default:
//! it is `#[ignore]`d AND does nothing unless `NOSTROMO_REAL_CLAUDE=1`. Every daemon file (session
//! store, model store, notes, activity log) lives in a temp dir; beyond what `claude` itself writes,
//! the one transcript directory it creates for the temp working directory is deleted afterwards.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use nostromo::data::work::picks::{transcript_dir_for, GeneratorEnv};
use nostromo::ipc::protocol::{EffortChoice, ModelRequestStatus, ServerMsg, SwitchPhase};
use nostromo::ipc::session_manager::{SwitchRequest, CLAUDE_BIN_ENV};
use nostromo::ipc::stream_json::{Turn, TurnBlock, TurnDelta};
use nostromo::ipc::SessionManager;
use nostromo::model::store::{self, FocusModelRecord, ModelSource};
use nostromo::model::{Actor, ModelPaths};
use tokio::sync::mpsc;

const TAG: &str = "real-model-switch";
/// Only a safety net against a hung turn; never part of a success condition.
const TURN_DEADLINE: Duration = Duration::from_secs(120);

fn opted_in() -> bool {
    if std::env::var("NOSTROMO_REAL_CLAUDE").as_deref() != Ok("1") {
        println!("model_switch_real_claude: skipped (set NOSTROMO_REAL_CLAUDE=1 to run against the real claude CLI)");
        return false;
    }
    true
}

/// Removes the env overrides and the transcript directory the real CLI made, however the test ends.
struct Cleanup {
    transcripts: Option<PathBuf>,
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        std::env::remove_var(CLAUDE_BIN_ENV);
        std::env::remove_var("NOSTROMO_ACTIVITY_PATH");
        if let Some(dir) = &self.transcripts {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}

/// Ends the session children when the test does (their blocking reader threads wait for it).
struct Mgr(SessionManager);

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

fn switch(model: Option<&str>, effort: Option<EffortChoice>) -> SwitchRequest {
    SwitchRequest { model: model.map(str::to_owned), effort, actor: Actor::User, set_as_agent_default: false, request_id: None }
}

struct Chat {
    rx: mpsc::UnboundedReceiver<ServerMsg>,
    completed: usize,
}

impl Chat {
    /// Block until `n` turns have ended in all.
    async fn wait_for_turns(&mut self, n: usize) {
        let started = Instant::now();
        while self.completed < n {
            assert!(started.elapsed() < TURN_DEADLINE, "turn {n} did not end within {TURN_DEADLINE:?}");
            match tokio::time::timeout(Duration::from_millis(200), self.rx.recv()).await {
                Ok(Some(ServerMsg::SessionTurnDelta { delta: TurnDelta::TurnCompleted { .. } | TurnDelta::TurnErrored { .. }, .. })) => {
                    self.completed += 1;
                }
                Ok(Some(_)) | Err(_) => {}
                Ok(None) => panic!("client channel closed"),
            }
        }
    }
}

/// Text of the newest turn's reply, as a freshly attaching client sees it.
fn last_reply(mgr: &mut SessionManager, probe: &str) -> String {
    let (tx, mut rx) = mpsc::unbounded_channel();
    mgr.client_sender_registry().lock().unwrap().insert(probe.to_owned(), tx);
    mgr.attach(TAG, probe).unwrap();
    let mut turns: Vec<Turn> = Vec::new();
    while let Ok(m) = rx.try_recv() {
        if let ServerMsg::SessionTurns { turns: t, .. } = m {
            turns = t;
        }
    }
    mgr.detach(TAG, probe);
    turns
        .last()
        .map(|t| t.blocks.iter().filter_map(|b| if let TurnBlock::Text { text, .. } = b { Some(text.as_str()) } else { None }).collect::<Vec<_>>().join(" "))
        .unwrap_or_default()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "opt-in: NOSTROMO_REAL_CLAUDE=1 cargo test --test model_switch_real_claude -- --ignored --nocapture"]
async fn a_real_session_switches_model_live_keeps_its_context_survives_a_bad_model_and_changes_effort() {
    if !opted_in() {
        return;
    }
    let real = PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/bin/claude");
    if !real.exists() {
        println!("model_switch_real_claude: skipped (no claude at {})", real.display());
        return;
    }

    let rig = tempfile::tempdir().unwrap();
    let wrapper = rig.path().join("claude");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\nexec \"{}\" \"$@\" --max-budget-usd 0.05 --setting-sources project --strict-mcp-config --tools \"\" --system-prompt \"Answer in one word.\"\n",
            real.display()
        ),
    )
    .unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    std::env::set_var(CLAUDE_BIN_ENV, &wrapper);
    std::env::set_var("NOSTROMO_ACTIVITY_PATH", rig.path().join("activity.jsonl"));
    let cwd = rig.path().join("cwd");
    std::fs::create_dir_all(&cwd).unwrap();

    let store_path = rig.path().join("state").join("sessions.json");
    let paths = ModelPaths::beside(&store_path);
    let projects = GeneratorEnv::local().projects_dir;
    let _cleanup = Cleanup { transcripts: projects.map(|p| transcript_dir_for(&p, &cwd)) };
    let mut mgr = Mgr(SessionManager::with_store_path(store_path));

    // The catalogue comes from the real CLI, exactly as the daemon fetches it.
    let catalog = nostromo::model::catalog::probe(&real).await.expect("the real CLI answers `initialize`");
    for family in ["haiku", "sonnet"] {
        assert!(catalog.family(family).is_some(), "the installed CLI offers {family}: {:?}", catalog.families);
    }
    mgr.set_model_catalog(catalog);

    // The focus starts on Haiku.
    store::update_focus_record(&paths.focus_models, TAG, |_| {
        Some(FocusModelRecord { model: "haiku".into(), effort: None, source: ModelSource::Focus, pending: None, ..FocusModelRecord::default() })
    })
    .unwrap();
    mgr.spawn_session(TAG.into(), String::new(), "real-model-switch".into(), Some(cwd), None, false).expect("the session starts");
    let (tx, rx) = mpsc::unbounded_channel();
    mgr.client_sender_registry().lock().unwrap().insert("window".into(), tx);
    mgr.attach(TAG, "window").unwrap();
    let mut chat = Chat { rx, completed: 0 };

    // 1. A fact, on Haiku.
    mgr.send_user_message(TAG, "The codeword is PLUM. Reply with just OK.", &[]).unwrap();
    chat.wait_for_turns(1).await;
    assert!(
        mgr.session_model_state(TAG).reported.is_some_and(|r| r.model.contains("haiku")),
        "the session says it runs Haiku: {:?}",
        mgr.session_model_state(TAG).reported
    );

    // 2. Switch to Sonnet; the context comes along.
    let outcome = mgr.request_switch(TAG, switch(Some("sonnet"), None)).outcome().await;
    assert_eq!(outcome.status, ModelRequestStatus::Applied, "{outcome:?}");
    mgr.send_user_message(TAG, "What was the codeword? One word.", &[]).unwrap();
    chat.wait_for_turns(2).await;
    let reply = last_reply(&mut mgr.0, "probe-1");
    assert!(reply.to_uppercase().contains("PLUM"), "the conversation survived the switch: {reply:?}");
    let reported = mgr.session_model_state(TAG).reported.expect("a reported model");
    assert!(reported.model.contains("sonnet"), "the session says it runs Sonnet: {reported:?}");
    assert_eq!(mgr.session_model_state(TAG).recorded.unwrap().model, "sonnet");

    // 3. A model that does not exist: refused by the CLI, the session carries on.
    let bad = mgr.request_switch(TAG, switch(Some("claude-no-such-model-xyz"), None)).outcome().await;
    assert_eq!(bad.status, ModelRequestStatus::Failed, "{bad:?}");
    assert_eq!(mgr.session_model_state(TAG).recorded.unwrap().model, "sonnet", "the recorded choice is unchanged");
    assert_eq!(mgr.session_model_state(TAG).phase, SwitchPhase::Steady);
    mgr.send_user_message(TAG, "Say hi.", &[]).unwrap();
    chat.wait_for_turns(3).await;
    assert!(!last_reply(&mut mgr.0, "probe-2").trim().is_empty(), "the session still answers after the failed switch");

    // 4. Effort, through apply_flag_settings and verified through get_settings.
    let low = mgr.request_switch(TAG, switch(None, Some(EffortChoice::Low))).outcome().await;
    assert_eq!(low.status, ModelRequestStatus::Applied, "{low:?}");
    assert_eq!(mgr.session_model_state(TAG).effective_effort.as_deref(), Some("low"));
    assert_eq!(store::focus_record(&paths.focus_models, TAG).unwrap().effort.as_deref(), Some("low"));
}
