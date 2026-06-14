//! MCP tool handlers for agent-authored pane assembly (daemon-hosted).
//!
//! - `nostromo.create_pane({ pane_id, position, relative_to, view_id? })` —
//!   split a named leaf, inserting a new pane.
//! - `nostromo.reset_panes({ view_id? })` — collapse the focus to a single REPL.
//!
//! Both operate against the daemon's [`PaneRegistry`] and broadcast a fresh
//! `ServerMsg::FocusLayout` so every connected client re-renders. They are only
//! meaningful in daemon-hosted mode; called against a TUI-hosted server they
//! return the stable `not_supported` error.

use serde_json::{json, Value};

use crate::ipc::pane_registry::SplitPosition;
use crate::ipc::protocol::ServerMsg;
use crate::mcp::state::McpSharedState;

/// Resolve the focus tag a layout tool targets: an explicit `view_id`, else the
/// caller's own focus (`pty_id` from the Hello frame, which in the daemon is the
/// focus tag). Returns `None` when neither is available.
fn target_tag<'a>(args: &'a Value, pty_id: Option<&'a str>) -> Option<&'a str> {
    args.get("view_id")
        .and_then(|v| v.as_str())
        .or(pty_id)
}

/// Handle `nostromo.create_pane`.
pub async fn create_pane(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "create_pane requires the daemon-hosted MCP server" });
    };

    let pane_id = match args.get("pane_id").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s,
        _ => return json!({ "error": "invalid_args", "detail": "missing pane_id" }),
    };
    let position = match args.get("position").and_then(|v| v.as_str()) {
        Some(s) => match SplitPosition::parse(s) {
            Ok(p) => p,
            Err(e) => return json!({ "error": e.code() }),
        },
        None => return json!({ "error": "invalid_args", "detail": "missing position" }),
    };
    let relative_to = match args.get("relative_to").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s,
        _ => return json!({ "error": "invalid_args", "detail": "missing relative_to" }),
    };

    // An explicit view_id targets another focus (must already exist). When the
    // agent targets its own focus we ensure the tree exists first.
    let explicit_view = args.get("view_id").and_then(|v| v.as_str()).is_some();
    let Some(tag) = target_tag(args, pty_id) else {
        return json!({ "error": "unidentified_caller" });
    };
    let tag = tag.to_string();

    let result = {
        let mut reg = daemon.pane_registry.lock().unwrap();
        if !explicit_view {
            reg.get_or_init(&tag);
        }
        reg.create_pane(&tag, pane_id, position, relative_to)
    };

    match result {
        Ok(tree) => {
            let _ = daemon.broadcast_tx.send(ServerMsg::FocusLayout {
                tag,
                tree: tree.clone(),
                focused_pane: None,
            });
            json!({ "ok": true, "tree": tree })
        }
        Err(e) => json!({ "error": e.code() }),
    }
}

/// Handle `nostromo.reset_panes`.
pub async fn reset_panes(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "reset_panes requires the daemon-hosted MCP server" });
    };

    let explicit_view = args.get("view_id").and_then(|v| v.as_str()).is_some();
    let Some(tag) = target_tag(args, pty_id) else {
        return json!({ "error": "unidentified_caller" });
    };
    let tag = tag.to_string();

    let result = {
        let mut reg = daemon.pane_registry.lock().unwrap();
        if !explicit_view {
            reg.get_or_init(&tag);
        }
        reg.reset(&tag)
    };

    match result {
        Ok(tree) => {
            let _ = daemon.broadcast_tx.send(ServerMsg::FocusLayout {
                tag,
                tree,
                focused_pane: None,
            });
            json!({ "ok": true })
        }
        Err(e) => json!({ "error": e.code() }),
    }
}
