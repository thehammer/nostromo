//! `nostromo.list_terminals`, `nostromo.request_follow` and
//! `nostromo.read_terminal_screen`: what an agent may do about the terminals
//! the user has open, and no more.
//!
//! An agent can *see that a terminal exists* (metadata only), *ask* the user to
//! let it follow one of its own focus's terminals, and, once the user has said
//! yes, read that terminal's current screen as redacted plain text. It cannot
//! type into a terminal, read one it was not invited to follow, or follow
//! without the user's click: the answer to its request comes from the verified
//! Nostromo app alone (the decision flow's own rule), and the invitation is
//! made by the call that waited for it. Every tool here takes a closed set of
//! keys (`unknown_argument` for any other) and no `view_id`: the caller is
//! always its own focus (its Hello `pty_id`).

use serde_json::{json, Map, Value};

use crate::mcp::state::McpSharedState;
use crate::terminal::agent_api::{AgentFollowRequest, FollowRequestResult};
use crate::terminal::remote_request::{DEFAULT_TIMEOUT, MAX_REASON_CHARS};

const TERMINAL_ID: &str = "terminal_id";
const REASON: &str = "reason";

/// Handle `nostromo.list_terminals`.
pub async fn list_terminals(
    state: &McpSharedState,
    arguments: Option<&Value>,
    pty_id: Option<&str>,
) -> Value {
    let (daemon, tag, _) = match caller(state, arguments, pty_id, &[]) {
        Ok(ok) => ok,
        Err(refusal) => return refusal,
    };
    let terminals: Vec<Value> = daemon
        .terminals
        .list_terminals(&tag)
        .into_iter()
        .map(|t| {
            json!({
                "terminal_id": t.terminal_id,
                "label": t.label,
                "kind": t.kind,
                "status": t.status,
                "followed_by_you": t.followed_by_you,
            })
        })
        .collect();
    json!({ "ok": true, "terminals": terminals })
}

/// Handle `nostromo.request_follow`.
pub async fn request_follow(
    state: &McpSharedState,
    arguments: Option<&Value>,
    pty_id: Option<&str>,
) -> Value {
    let (daemon, tag, args) = match caller(state, arguments, pty_id, &[TERMINAL_ID, REASON]) {
        Ok(ok) => ok,
        Err(refusal) => return refusal,
    };
    let terminal_id = match terminal_id(&args) {
        Ok(id) => id,
        Err(refusal) => return refusal,
    };
    let reason = match args.get(REASON) {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.chars().count() <= MAX_REASON_CHARS => Some(s.clone()),
        Some(Value::String(_)) => {
            return json!({ "error": "reason_too_long", "detail": format!("at most {MAX_REASON_CHARS} characters") })
        }
        Some(_) => return json!({ "error": "invalid_args", "detail": "reason must be a string" }),
    };
    let agent = super::remote_shell::agent_name(daemon, &tag);

    let result = daemon
        .terminals
        .request_follow(
            AgentFollowRequest {
                tag,
                agent,
                terminal_id,
                reason,
                timeout: DEFAULT_TIMEOUT,
            },
            &daemon.decisions,
            &daemon.broadcast_tx,
        )
        .await;
    match result {
        FollowRequestResult::Following => json!({ "ok": true, "outcome": "following" }),
        FollowRequestResult::Denied => json!({ "error": "denied" }),
        FollowRequestResult::Dismissed => json!({ "error": "dismissed" }),
        FollowRequestResult::TimedOut => json!({ "error": "timeout" }),
        FollowRequestResult::NoOperator => json!({ "error": "no_operator" }),
        FollowRequestResult::Cancelled => json!({ "error": "cancelled" }),
        FollowRequestResult::Refused(code) => json!({ "error": code }),
    }
}

/// Handle `nostromo.read_terminal_screen`.
pub async fn read_screen(
    state: &McpSharedState,
    arguments: Option<&Value>,
    pty_id: Option<&str>,
) -> Value {
    let (daemon, tag, args) = match caller(state, arguments, pty_id, &[TERMINAL_ID]) {
        Ok(ok) => ok,
        Err(refusal) => return refusal,
    };
    let terminal_id = match terminal_id(&args) {
        Ok(id) => id,
        Err(refusal) => return refusal,
    };
    match daemon
        .terminals
        .read_screen_if_following(&tag, &terminal_id)
    {
        Ok(screen) => json!({
            "ok": true,
            "text": screen.text,
            "lines": screen.lines,
            "redactions": screen.redactions,
        }),
        Err(refused) => json!({ "error": refused.code() }),
    }
}

/// The daemon, the caller's own focus and the arguments, once the arguments
/// hold only `allowed` keys and the caller is a focus the daemon knows. Else
/// the refusal to return.
fn caller<'a>(
    state: &'a McpSharedState,
    arguments: Option<&Value>,
    pty_id: Option<&str>,
    allowed: &[&str],
) -> Result<
    (
        &'a crate::mcp::state::DaemonMcpBackend,
        String,
        Map<String, Value>,
    ),
    Value,
> {
    let Some(daemon) = &state.daemon else {
        return Err(
            json!({ "error": "not_supported", "detail": "terminal tools require the daemon-hosted MCP server" }),
        );
    };
    let args: Map<String, Value> = match arguments {
        None | Some(Value::Null) => Map::new(),
        Some(Value::Object(o)) => o.clone(),
        Some(_) => {
            return Err(json!({ "error": "invalid_args", "detail": "arguments must be an object" }))
        }
    };
    // Any key beyond the closed set is refused before anything else is looked at.
    if let Some(key) = args.keys().find(|k| !allowed.contains(&k.as_str())) {
        return Err(json!({ "error": "unknown_argument", "detail": key }));
    }
    let Some(tag) = pty_id.filter(|t| !t.is_empty()) else {
        return Err(json!({ "error": "unknown_view" }));
    };
    if !super::terminal::focus_exists(state, tag) {
        return Err(json!({ "error": "unknown_view" }));
    }
    Ok((daemon, tag.to_string(), args))
}

/// The required `terminal_id` argument: a non-empty string.
fn terminal_id(args: &Map<String, Value>) -> Result<String, Value> {
    match args.get(TERMINAL_ID) {
        Some(Value::String(s)) if !s.is_empty() => Ok(s.clone()),
        _ => {
            Err(json!({ "error": "invalid_args", "detail": "terminal_id is required (a string)" }))
        }
    }
}
