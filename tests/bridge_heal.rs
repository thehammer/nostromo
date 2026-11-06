//! A session whose `nostromo-mcp-bridge` goes away gets its tools back
//! without the operator: the daemon asks the session's CLI to reconnect the
//! `nostromo` MCP server (`mcp_reconnect`), because Claude Code never
//! respawns a stdio server by itself and a Nostromo pane has no `/mcp` menu.
//!
//! The session is a `/bin/sh` stub (never the real CLI): it logs every
//! `mcp_reconnect` request and answers it, and the test plays the bridge by
//! calling `bridge_opened` / `bridge_closed` as the MCP server does.

use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicUsize;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::SessionManager;
use nostromo::mcp::state::{DaemonMcpBackend, McpSharedState, PerriDaemonState};

const TAG: &str = "careport-1";

fn stub_script(log: &Path) -> String {
    format!(
        r#"while IFS= read -r line; do
  case "$line" in
    *'"type":"control_request"'*)
      rid=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
      printf '%s\n' "$line" >> '{log}'
      printf '%s\n' "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"success\",\"request_id\":\"$rid\"}}}}"
      continue ;;
  esac
done
"#,
        log = log.display(),
    )
}

struct Fixture {
    _dir: tempfile::TempDir,
    state: McpSharedState,
    sessions: Arc<Mutex<SessionManager>>,
    log: PathBuf,
}

fn fixture(delays: &[Duration]) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let sessions = Arc::new(Mutex::new(SessionManager::with_store_path(
        dir.path().join("sessions.json"),
    )));
    let (broadcast_tx, _rx) = tokio::sync::broadcast::channel(64);
    let mut state = McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: Arc::new(Mutex::new(PaneRegistry::with_store_path(
            dir.path().join("panes.json"),
        ))),
        session_mgr: Arc::clone(&sessions),
        broadcast_tx,
        perri: PerriDaemonState {
            state_dir: Some(dir.path().join("perri-state")),
            pr_refresh_tx: None,
            queue_refresh_tx: None,
            selected_index: Arc::new(AtomicUsize::new(0)),
            settle_timeout: Duration::from_millis(50),
        },
        decisions: Default::default(),
        tickets: Default::default(),
        tracker: Default::default(),
        terminals: nostromo::terminal::TerminalAgentApi::in_memory(),
    });
    state.bridge_heal_delays = Arc::from(delays);
    let log = dir.path().join("control.log");
    Fixture {
        _dir: dir,
        state,
        sessions,
        log,
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .kill_all_on_shutdown();
    }
}

impl Fixture {
    fn spawn_session(&self) {
        self.sessions
            .lock()
            .unwrap()
            .spawn_program_for_test(
                TAG,
                PathBuf::from("/bin/sh"),
                vec!["-c".into(), stub_script(&self.log)],
            )
            .expect("spawn the stub session");
    }

    fn requests(&self) -> Vec<serde_json::Value> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(|l| serde_json::from_str(l).expect("a logged frame is JSON"))
            .collect()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn closing_the_last_bridge_is_enough_to_get_a_reconnect() {
    // Only what the MCP server does when a bridge's socket ends: no manual heal.
    let f = fixture(&[Duration::from_millis(50)]);
    f.spawn_session();
    f.state.bridge_opened(TAG);
    f.state.bridge_closed(TAG);

    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while f.requests().is_empty() && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let requests = f.requests();
    assert_eq!(
        requests.len(),
        1,
        "bridge_closed alone must lead to one reconnect request"
    );
    let r = &requests[0];
    assert_eq!(r["type"], "control_request");
    assert_eq!(r["request"]["subtype"], "mcp_reconnect");
    assert_eq!(r["request"]["serverName"], "nostromo");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_lost_bridge_is_reconnected_through_the_session() {
    let f = fixture(&[Duration::from_millis(50)]);
    f.spawn_session();
    f.state.bridge_opened(TAG);
    // Not via bridge_closed, so this heal is the only one.
    f.state.bridges.close(TAG);

    let sent = f.state.heal_bridge(TAG.to_owned()).await;

    assert_eq!(sent, 1, "one reconnect request while the bridge is gone");
    assert_eq!(f.requests().len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_bridge_that_comes_back_by_itself_is_left_alone() {
    let f = fixture(&[Duration::from_millis(1_000)]);
    f.spawn_session();
    f.state.bridge_opened(TAG);
    f.state.bridge_closed(TAG);
    // The bridge reconnects on its own (a daemon restart) well inside the wait.
    f.state.bridge_opened(TAG);

    tokio::time::sleep(Duration::from_millis(1_500)).await;
    assert!(
        f.requests().is_empty(),
        "no reconnect for a bridge that came back"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn it_retries_after_each_wait_and_then_gives_up() {
    let f = fixture(&[
        Duration::from_millis(30),
        Duration::from_millis(30),
        Duration::from_millis(30),
    ]);
    f.spawn_session();
    f.state.bridge_opened(TAG);
    // Not via bridge_closed: drive one heal by hand so the count is exact.
    f.state.bridges.close(TAG);

    let sent = f.state.heal_bridge(TAG.to_owned()).await;

    assert_eq!(
        sent, 3,
        "every wait ends in a request while the bridge stays gone"
    );
    assert_eq!(f.requests().len(), 3);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_that_is_not_running_is_not_retried() {
    let f = fixture(&[Duration::from_millis(10), Duration::from_millis(10)]);
    // No session spawned for TAG.
    f.state.bridge_opened(TAG);
    f.state.bridges.close(TAG);

    let sent = f.state.heal_bridge(TAG.to_owned()).await;

    assert_eq!(
        sent, 1,
        "the first attempt learns there is no session and stops"
    );
}
