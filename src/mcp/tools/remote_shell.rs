//! `nostromo.list_remote_shell_targets` and `nostromo.request_remote_shell`:
//! an agent *asks* for a shell on a remote (ECS) service, and the user decides.
//!
//! The request takes four words from a closed vocabulary (project,
//! environment, service, shell type; aliases such as `prod` accepted) and an
//! optional reason. It has no command, script or argument field: an agent
//! cannot choose what runs, and any other key is refused (`unknown_argument`).
//! The call blocks until the user clicks Connect in the Nostromo app, cancels
//! or dismisses the sheet, or the request times out. Opening the shell is the
//! user's act alone; the agent never types into it and cannot see its output
//! unless the user later invites it to follow. These tools are the sanctioned
//! way to get a production shell: the `ecs_*` shell functions and tmux panes
//! are blocked for agents by the production-shell guard (see
//! `crate::approvals::guard`), which allows these two.

use serde_json::{json, Map, Value};

use crate::mcp::state::McpSharedState;
use crate::terminal::agent_api::AgentRemoteRequest;
use crate::terminal::ecs::InvalidTarget;
use crate::terminal::remote_request::{RemoteResult, DEFAULT_TIMEOUT, MAX_REASON_CHARS};

/// The keys the request accepts. Anything else is `unknown_argument`.
const REQUEST_KEYS: [&str; 5] = ["project", "environment", "service", "shell_type", "reason"];

/// Handle `nostromo.list_remote_shell_targets`.
pub async fn list_targets(state: &McpSharedState, arguments: Option<&Value>) -> Value {
    let Some(daemon) = &state.daemon else {
        return not_supported();
    };
    if let Some(key) = first_key(arguments, &[]) {
        return json!({ "error": "unknown_argument", "detail": key });
    }
    match daemon.terminals.list_remote_targets() {
        Ok(targets) => json!({
            "ok": true,
            "projects": targets.projects,
            "shell_types": targets.shell_types,
        }),
        Err(e) => json!({ "error": "remote_shells_not_configured", "detail": e.problem }),
    }
}

/// Handle `nostromo.request_remote_shell`.
pub async fn request_shell(
    state: &McpSharedState,
    arguments: Option<&Value>,
    pty_id: Option<&str>,
) -> Value {
    let Some(daemon) = &state.daemon else {
        return not_supported();
    };
    let object: Map<String, Value> = match arguments {
        None | Some(Value::Null) => Map::new(),
        Some(Value::Object(o)) => o.clone(),
        Some(_) => {
            return json!({ "error": "invalid_args", "detail": "arguments must be an object" })
        }
    };
    // Any key beyond the closed set (`command`, `cmd`, `script`, …) is refused
    // before anything else is looked at.
    if let Some(key) = object.keys().find(|k| !REQUEST_KEYS.contains(&k.as_str())) {
        return json!({ "error": "unknown_argument", "detail": key });
    }
    let mut words = [""; 4];
    for (slot, key) in words.iter_mut().zip(&REQUEST_KEYS[..4]) {
        match object.get(*key) {
            Some(Value::String(s)) => *slot = s,
            _ => {
                return json!({ "error": "invalid_args", "detail": format!("{key} is required (a string)") })
            }
        }
    }
    let reason = match object.get("reason") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.chars().count() <= MAX_REASON_CHARS => Some(s.clone()),
        Some(Value::String(_)) => {
            return json!({ "error": "reason_too_long", "detail": format!("at most {MAX_REASON_CHARS} characters") })
        }
        Some(_) => return json!({ "error": "invalid_args", "detail": "reason must be a string" }),
    };

    // The caller's own focus, and only that.
    let Some(tag) = pty_id.filter(|t| !t.is_empty()) else {
        return json!({ "error": "unknown_view" });
    };
    if !super::terminal::focus_exists(state, tag) {
        return json!({ "error": "unknown_view" });
    }
    let agent = daemon.session_mgr.lock().ok().and_then(|m| {
        m.focus_registry()
            .into_iter()
            .find(|f| f.tag == tag)
            .map(|f| f.agent_name)
            .filter(|a| !a.is_empty())
    });

    let [project, environment, service, shell_type] = words;
    let result = daemon
        .terminals
        .request_remote(AgentRemoteRequest {
            tag: tag.to_string(),
            agent,
            project: project.to_string(),
            environment: environment.to_string(),
            service: service.to_string(),
            shell_type: shell_type.to_string(),
            reason,
            timeout: DEFAULT_TIMEOUT,
        })
        .await;
    result_json(result)
}

/// What each way a request can end looks like to the agent.
fn result_json(result: RemoteResult) -> Value {
    match result {
        RemoteResult::Connected(info) => json!({
            "ok": true,
            "outcome": "connected",
            "terminal_id": info.terminal_id,
            "pane_id": info.pane_id,
        }),
        RemoteResult::NotConfigured(problem) => {
            json!({ "error": "remote_shells_not_configured", "detail": problem })
        }
        RemoteResult::InvalidTarget(invalid) => invalid_target_json(&invalid),
        RemoteResult::NoOperator => json!({ "error": "no_operator" }),
        RemoteResult::RequestPending => json!({ "error": "request_pending" }),
        RemoteResult::RequestCooldown => json!({ "error": "request_cooldown" }),
        RemoteResult::RequestLimit => json!({ "error": "request_limit" }),
        RemoteResult::Superseded => json!({ "error": "superseded" }),
        RemoteResult::Cancelled => json!({ "error": "cancelled" }),
        RemoteResult::Dismissed => json!({ "error": "dismissed" }),
        RemoteResult::TimedOut => json!({ "error": "timeout" }),
        // The agent gets the code and the fixed remedy for it, and nothing the
        // AWS CLI printed (not the message, not the first line: those are for
        // the person at the app).
        RemoteResult::ConnectFailed(failure) => json!({
            "error": "connect_failed",
            "reason": failure.reason_code,
            "remedy": failure.remedy,
        }),
    }
}

fn invalid_target_json(invalid: &InvalidTarget) -> Value {
    json!({
        "error": "invalid_target",
        "detail": invalid.detail(),
        "valid": { "field": invalid.field.as_str(), "values": invalid.valid },
    })
}

fn not_supported() -> Value {
    json!({ "error": "not_supported", "detail": "remote shells require the daemon-hosted MCP server" })
}

/// The first argument key not in `allowed`, if the arguments are an object.
fn first_key(arguments: Option<&Value>, allowed: &[&str]) -> Option<String> {
    arguments
        .and_then(Value::as_object)
        .and_then(|o| o.keys().find(|k| !allowed.contains(&k.as_str())).cloned())
}
