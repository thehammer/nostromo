//! The MCP panel's daemon half (`session_mcp_v1`): `SessionManager::mcp` against
//! a `/bin/sh` stub CLI (never the real one) that logs every control request
//! and answers `mcp_status` with a canned body full of secrets.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::protocol::{McpAction, McpOutcome, ServerMsg};
use nostromo::ipc::session_manager::mcp_panel::McpReply;
use nostromo::ipc::SessionManager;
use nostromo::mcp::BridgeRegistry;

const TAG: &str = "careport-1";

/// Every secret the canned status carries. None may appear in a reply.
const SECRETS: [&str; 10] = [
    "SECRET123",
    "hunter2",
    "token=abc",
    "Bearer",
    "zzz",
    "key=",
    "command",
    "args",
    "url",
    "x.example/mcp?",
];

fn status_line() -> String {
    let body = serde_json::json!({"mcpServers": [
        {"name": "nostromo", "status": "connected", "scope": "user", "source": "user", "transport": "stdio",
         "config": {"type": "stdio", "command": "/bin/secret-cmd", "args": ["--password", "hunter2"],
                    "env": {"API_TOKEN": "sk-live-SECRET123"}},
         "tools": [{"name": "a"}, {"name": "b"}, {"name": "c"}]},
        {"name": "remote", "status": "connected", "scope": "claudeai", "source": "claudeai", "transport": "http",
         "config": {"type": "http", "url": "https://x.example/mcp?token=abc",
                    "headers": {"Authorization": "Bearer zzz"}},
         "urlHost": "x.example", "serverInfo": {"name": "zzz"}, "tools": []},
        {"name": "odd", "status": "weird-new-state", "someNewField": {"deep": 1}, "tools": [{"name": "t"}]},
        {"name": "broken", "status": "failed", "transport": "http",
         "error": "502 Bad Gateway from https://x.example/mcp?key=live123#frag"},
        {"name": "gh", "status": "needs-auth", "transport": "http"}
    ]});
    serde_json::json!({"type": "control_response",
        "response": {"subtype": "success", "request_id": "__RID__", "response": body}})
    .to_string()
}

fn stub_script(dir: &Path) -> String {
    format!(
        r#"while IFS= read -r line; do
  case "$line" in
    *'"type":"control_request"'*)
      rid=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
      sub=$(printf '%s' "$line" | sed -n 's/.*"subtype":"\([^"]*\)".*/\1/p')
      printf '%s\n' "$line" >> '{d}/control.log'
      mode=$(cat '{d}/mode' 2>/dev/null)
      case "$mode" in
        silent) continue ;;
        unsupported)
          printf '%s\n' "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"error\",\"request_id\":\"$rid\",\"error\":\"Unsupported control request subtype: $sub\"}}}}"
          continue ;;
        toggle_error)
          if [ "$sub" = mcp_toggle ]; then
            printf '%s\n' "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"error\",\"request_id\":\"$rid\",\"error\":\"Server status: needs-auth\"}}}}"
            continue
          fi ;;
      esac
      if [ "$sub" = mcp_status ]; then
        sed "s|__RID__|$rid|" '{d}/status.json'
      else
        printf '%s\n' "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"success\",\"request_id\":\"$rid\"}}}}"
      fi
      continue ;;
  esac
done
"#,
        d = dir.display(),
    )
}

struct Fixture {
    dir: tempfile::TempDir,
    mgr: Arc<Mutex<SessionManager>>,
    bridges: Arc<BridgeRegistry>,
}

fn fixture(spawn: bool) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("status.json"), status_line() + "\n").unwrap();
    let mut mgr = SessionManager::with_store_path(dir.path().join("sessions.json"));
    let bridges = Arc::new(BridgeRegistry::default());
    mgr.configure_bridge_registry(Arc::clone(&bridges));
    mgr.set_mcp_wait_for_test(Duration::from_millis(600));
    if spawn {
        mgr.spawn_program_for_test(
            TAG,
            PathBuf::from("/bin/sh"),
            vec!["-c".into(), stub_script(dir.path())],
        )
        .expect("spawn the stub session");
    }
    Fixture {
        dir,
        mgr: Arc::new(Mutex::new(mgr)),
        bridges,
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.mgr
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .kill_all_on_shutdown();
    }
}

impl Fixture {
    async fn mcp(
        &self,
        action: McpAction,
        server: Option<&str>,
        enabled: Option<bool>,
    ) -> McpReply {
        let run = self
            .mgr
            .lock()
            .unwrap()
            .mcp(TAG, action, server.map(str::to_owned), enabled);
        run.await
    }

    fn set_mode(&self, mode: &str) {
        std::fs::write(self.dir.path().join("mode"), mode).unwrap();
    }

    /// `(subtype, request)` for each control request the stub saw.
    fn requests(&self) -> Vec<(String, serde_json::Value)> {
        std::fs::read_to_string(self.dir.path().join("control.log"))
            .unwrap_or_default()
            .lines()
            .map(|l| {
                let v: serde_json::Value = serde_json::from_str(l).unwrap();
                (
                    v["request"]["subtype"].as_str().unwrap().to_owned(),
                    v["request"].clone(),
                )
            })
            .collect()
    }

    fn subtypes(&self) -> Vec<String> {
        self.requests().into_iter().map(|r| r.0).collect()
    }
}

fn wire(reply: &McpReply) -> String {
    serde_json::to_string(&ServerMsg::SessionMcpResult {
        request_id: "r".into(),
        tag: TAG.into(),
        action: McpAction::Status,
        outcome: reply.outcome,
        message: reply.message.clone(),
        servers: reply.servers.clone(),
    })
    .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn status_carries_names_and_states_and_none_of_the_secrets() {
    let f = fixture(true);
    let reply = f.mcp(McpAction::Status, None, None).await;
    assert_eq!(reply.outcome, McpOutcome::Ok);

    let json = wire(&reply);
    for secret in SECRETS {
        assert!(!json.contains(secret), "{secret:?} leaked: {json}");
    }

    let servers = reply.servers.unwrap();
    assert_eq!(servers.len(), 5);
    let remote = servers.iter().find(|s| s.name == "remote").unwrap();
    assert_eq!(remote.scope.as_deref(), Some("claudeai"));
    assert_eq!(remote.transport.as_deref(), Some("http"));
    assert_eq!(remote.tool_count, Some(0));
    let odd = servers.iter().find(|s| s.name == "odd").unwrap();
    assert_eq!(odd.status, "weird-new-state", "an unknown status stays raw");
    assert_eq!(odd.tool_count, Some(1));
    let gh = servers.iter().find(|s| s.name == "gh").unwrap();
    assert_eq!(gh.tool_count, None, "no tools key means unknown");
    let broken = servers.iter().find(|s| s.name == "broken").unwrap();
    let error = broken.error.as_deref().unwrap();
    assert!(error.contains("502 Bad Gateway"), "{error}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_nostromo_bridge_flag_follows_the_daemons_bridge_state() {
    let f = fixture(true);
    f.bridges.open(TAG);
    let up = f.mcp(McpAction::Status, None, None).await.servers.unwrap();
    assert_eq!(
        up.iter()
            .find(|s| s.name == "nostromo")
            .unwrap()
            .nostromo_bridge,
        Some(true)
    );
    assert_eq!(
        up.iter()
            .find(|s| s.name == "remote")
            .unwrap()
            .nostromo_bridge,
        None
    );

    f.bridges.close(TAG);
    tokio::time::sleep(Duration::from_millis(1100)).await;
    let down = f.mcp(McpAction::Status, None, None).await.servers.unwrap();
    assert_eq!(
        down.iter()
            .find(|s| s.name == "nostromo")
            .unwrap()
            .nostromo_bridge,
        Some(false)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn status_asked_again_within_a_second_comes_from_the_last_list() {
    let f = fixture(true);
    let first = f.mcp(McpAction::Status, None, None).await;
    let second = f.mcp(McpAction::Status, None, None).await;
    assert_eq!(second.outcome, McpOutcome::Ok);
    assert_eq!(second.servers, first.servers);
    assert_eq!(f.subtypes(), ["mcp_status"], "one status sent");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn reconnect_sends_one_request_then_a_fresh_status() {
    let f = fixture(true);
    let reply = f.mcp(McpAction::Reconnect, Some("odd"), None).await;
    assert_eq!(reply.outcome, McpOutcome::Ok);
    assert!(
        reply.servers.is_some(),
        "the reply carries the refreshed list"
    );
    assert_eq!(f.subtypes(), ["mcp_reconnect", "mcp_status"]);
    assert_eq!(f.requests()[0].1["serverName"], "odd");
    for secret in SECRETS {
        assert!(!wire(&reply).contains(secret));
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_second_reconnect_inside_five_seconds_is_rate_limited_and_sends_nothing() {
    let f = fixture(true);
    f.mcp(McpAction::Reconnect, Some("odd"), None).await;
    let before = f.requests().len();

    let again = f.mcp(McpAction::Reconnect, Some("odd"), None).await;
    assert_eq!(again.outcome, McpOutcome::RateLimited);
    assert!(again.message.unwrap().contains("wait"));
    let toggled = f.mcp(McpAction::Toggle, Some("odd"), Some(false)).await;
    assert_eq!(
        toggled.outcome,
        McpOutcome::RateLimited,
        "toggle shares the server's limit"
    );
    assert_eq!(f.requests().len(), before, "nothing sent");

    // Another server is not held back.
    let other = f.mcp(McpAction::Reconnect, Some("gh"), None).await;
    assert_eq!(other.outcome, McpOutcome::Ok);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn toggle_sends_the_name_and_state_and_refreshes() {
    let f = fixture(true);
    let reply = f.mcp(McpAction::Toggle, Some("odd"), Some(false)).await;
    assert_eq!(reply.outcome, McpOutcome::Ok);
    assert_eq!(f.subtypes(), ["mcp_toggle", "mcp_status"]);
    let req = &f.requests()[0].1;
    assert_eq!(req["serverName"], "odd");
    assert_eq!(req["enabled"], false);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn disabling_nostromo_is_invalid_and_sends_nothing() {
    let f = fixture(true);
    let reply = f
        .mcp(McpAction::Toggle, Some("nostromo"), Some(false))
        .await;
    assert_eq!(reply.outcome, McpOutcome::Invalid);
    assert!(f.requests().is_empty());
    // Enabling it is allowed.
    let enable = f.mcp(McpAction::Toggle, Some("nostromo"), Some(true)).await;
    assert_eq!(enable.outcome, McpOutcome::Ok);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_requests_are_invalid_and_send_nothing() {
    let f = fixture(true);
    assert_eq!(
        f.mcp(McpAction::Reconnect, None, None).await.outcome,
        McpOutcome::Invalid
    );
    assert_eq!(
        f.mcp(McpAction::Toggle, Some("odd"), None).await.outcome,
        McpOutcome::Invalid
    );
    assert_eq!(
        f.mcp(McpAction::Unknown, Some("odd"), None).await.outcome,
        McpOutcome::Invalid
    );
    assert!(f.requests().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_enable_that_errors_but_took_effect_is_ok_with_the_cli_text() {
    let f = fixture(true);
    f.set_mode("toggle_error");
    // The canned status shows `gh` as needs-auth: not disabled, so enabled.
    let reply = f.mcp(McpAction::Toggle, Some("gh"), Some(true)).await;
    assert_eq!(reply.outcome, McpOutcome::Ok);
    assert!(reply.message.unwrap().contains("needs-auth"));
    assert!(reply.servers.is_some());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_toggle_error_that_changed_nothing_is_refused() {
    let f = fixture(true);
    f.set_mode("toggle_error");
    // Asking to disable `gh`, which the status still shows as not disabled.
    let reply = f.mcp(McpAction::Toggle, Some("gh"), Some(false)).await;
    assert_eq!(reply.outcome, McpOutcome::Refused);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_old_cli_is_unsupported() {
    let f = fixture(true);
    f.set_mode("unsupported");
    let reply = f.mcp(McpAction::Status, None, None).await;
    assert_eq!(reply.outcome, McpOutcome::Unsupported);
    assert!(reply.message.unwrap().contains("too old"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_silent_cli_times_out() {
    let f = fixture(true);
    f.set_mode("silent");
    let reply = f.mcp(McpAction::Status, None, None).await;
    assert_eq!(reply.outcome, McpOutcome::Timeout);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_that_is_not_running_gets_not_running_and_nothing_is_written() {
    let f = fixture(false);
    for action in [McpAction::Status, McpAction::Reconnect, McpAction::Toggle] {
        let reply = f.mcp(action, Some("odd"), Some(true)).await;
        assert_eq!(reply.outcome, McpOutcome::NotRunning);
        assert_eq!(reply.message.as_deref(), Some("the session is not running"));
    }
    assert!(f.requests().is_empty());
}
