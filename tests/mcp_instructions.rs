//! `initialize` `instructions` (PRD 28, server half): only a session the daemon spawned gets them;
//! everyone else gets the response it always did.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{FocusMeta, ServerMsg};
use nostromo::ipc::SessionManager;
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState, PerriDaemonState};
use nostromo::tracker::{CallerFacts, FakeClock, RegistryParts, TrackerRegistry};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, watch};

const PICKS: &str = "teri-picks";

struct Harness {
    state: McpSharedState,
    registry: Arc<TrackerRegistry>,
    repo: PathBuf,
    dir: TempDir,
}

fn focus(tag: &str) -> FocusMeta {
    FocusMeta {
        tag: tag.into(),
        display_name: tag.into(),
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

fn harness(focuses: &[&str]) -> Harness {
    let dir = TempDir::new().unwrap();
    let base = dir.path().canonicalize().unwrap();
    let repo = base.join("repo");
    for d in [&repo, &base.join("home"), &base.join("state")] {
        std::fs::create_dir_all(d).unwrap();
    }
    let git = Command::new("git")
        .args(["init", "-q"])
        .current_dir(&repo)
        .output()
        .unwrap();
    assert!(git.status.success());
    let registry = Arc::new(TrackerRegistry::new(RegistryParts::hermetic(
        base.join("state"),
        base.join("home"),
        Arc::new(FakeClock::at_secs(1_760_540_000)),
    )));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        base.join("sessions.json"),
    )));
    session_mgr
        .lock()
        .unwrap()
        .set_focus_registry(focuses.iter().map(|t| focus(t)).collect());
    let (tx, _rx) = broadcast::channel::<ServerMsg>(64);
    let state = McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: Arc::new(Mutex::new(PaneRegistry::with_store_path(
            base.join("panes.json"),
        ))),
        session_mgr,
        broadcast_tx: tx,
        perri: PerriDaemonState::default(),
        decisions: Arc::new(Mutex::new(
            nostromo::ipc::decisions::DecisionRegistry::default(),
        )),
        tickets: Default::default(),
        tracker: Arc::clone(&registry),
        terminals: nostromo::terminal::TerminalAgentApi::in_memory(),
    });
    Harness {
        state,
        registry,
        repo,
        dir,
    }
}

fn tui_state() -> McpSharedState {
    McpSharedState::new(
        watch::channel(None).1,
        watch::channel(Default::default()).1,
        watch::channel(None).1,
        watch::channel(None).1,
        watch::channel(None).1,
        watch::channel(Vec::new()).1,
        watch::channel(None).1,
        watch::channel(None).1,
        watch::channel(None).1,
    )
}

/// Connects with `hello` as the Hello frame and returns the `initialize` response.
async fn initialize(state: &McpSharedState, dir: &Path, hello: Value) -> Value {
    let sock = dir.join(format!("mcp-{}.sock", std::process::id()));
    let _server = McpServer::bind(sock.clone(), state.clone()).await.unwrap();
    let stream = UnixStream::connect(&sock).await.unwrap();
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r);
    for frame in [
        hello,
        json!({"jsonrpc":"2.0","id":1,"method":"initialize",
               "params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}),
    ] {
        let mut bytes = serde_json::to_vec(&frame).unwrap();
        bytes.push(b'\n');
        w.write_all(&bytes).await.unwrap();
    }
    let mut line = String::new();
    reader.read_line(&mut line).await.unwrap();
    serde_json::from_str(line.trim()).unwrap()
}

fn todays_response() -> Value {
    json!({
        "jsonrpc": "2.0", "id": 1,
        "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "nostromo", "version": env!("CARGO_PKG_VERSION")}
        }
    })
}

#[tokio::test]
async fn a_known_daemon_focus_gets_the_tracker_instructions() {
    let h = harness(&["cody-1"]);
    let resp = initialize(
        &h.state,
        h.dir.path(),
        json!({"type":"hello","pty_id":"cody-1"}),
    )
    .await;
    let text = resp["result"]["instructions"]
        .as_str()
        .expect("instructions");
    for needle in [
        "mcp__nostromo__nostromo_tracker",
        "keep track",
        "never put resident or patient names, dates of birth, medical record numbers, diagnoses, contact details or raw database rows",
    ] {
        assert!(text.contains(needle), "missing {needle:?} in {text}");
    }
    assert!(text.chars().count() <= 3_200);
    assert!(!text.contains("A tracker is open"));
}

#[tokio::test]
async fn every_other_caller_gets_todays_bytes() {
    let h = harness(&["cody-1", PICKS]);
    let cases = [
        ("no pty_id", json!({"type":"hello"})),
        ("empty pty_id", json!({"type":"hello","pty_id":""})),
        ("unknown pty_id", json!({"type":"hello","pty_id":"nobody"})),
        ("picks tag", json!({"type":"hello","pty_id":PICKS})),
    ];
    for (why, hello) in cases {
        let resp = initialize(&h.state, h.dir.path(), hello).await;
        assert_eq!(resp, todays_response(), "{why}");
    }
    let tui = tui_state();
    let resp = initialize(
        &tui,
        h.dir.path(),
        json!({"type":"hello","pty_id":"cody-1"}),
    )
    .await;
    assert_eq!(resp, todays_response(), "TUI-hosted server");
}

#[tokio::test]
async fn a_focus_with_a_bound_board_is_told_its_topic_and_stays_in_budget() {
    let h = harness(&["cody-1", "cody-2"]);
    h.registry.set_caller_facts(
        "cody-1",
        CallerFacts {
            cwd: Some(h.repo.clone()),
            session_id: Some("s1".into()),
        },
    );
    let opened = nostromo::mcp::tools::dispatch(
        "nostromo.tracker",
        Some(&json!({"op":"open","topic":"sentry-triage"})),
        &h.state,
        Some("cody-1"),
    )
    .await;
    assert!(matches!(opened, nostromo::mcp::tools::ToolResult::Ok(_)));

    let bound = initialize(
        &h.state,
        h.dir.path(),
        json!({"type":"hello","pty_id":"cody-1"}),
    )
    .await;
    let text = bound["result"]["instructions"].as_str().unwrap();
    assert!(text.contains(
        "A tracker is open in this focus: \"sentry-triage\". Call op:\"read\" to load it."
    ));
    assert!(text.chars().count() <= 3_200);

    let other = initialize(
        &h.state,
        h.dir.path(),
        json!({"type":"hello","pty_id":"cody-2"}),
    )
    .await;
    assert!(!other["result"]["instructions"]
        .as_str()
        .unwrap()
        .contains("A tracker is open"));
}
