//! MCP tool handler for `nostromo.create_focus` (daemon-hosted).
//!
//! Programmatically creates a new persistent focus running a named agent
//! persona, seeds its first turn with `initial_context`, registers it in the
//! daemon's focus registry, and broadcasts `FocusCreated` so every client adds
//! the tab. Returns `{ "focus_id": "<tag>" }`.

use std::path::PathBuf;

use serde_json::{json, Value};

use crate::ipc::protocol::{FocusMeta, PaneTree, ServerMsg};
use crate::mcp::state::McpSharedState;

/// Derive a stable, filesystem/IPC-safe focus tag from an agent name + title.
/// e.g. ("cody", "CORE-1234") -> "cody-core-1234".
fn derive_tag(agent: &str, title: &str) -> String {
    let slug: String = title
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
        .collect();
    // Collapse runs of '-' and trim.
    let mut collapsed = String::with_capacity(slug.len());
    let mut prev_dash = false;
    for c in slug.chars() {
        if c == '-' {
            if !prev_dash {
                collapsed.push('-');
            }
            prev_dash = true;
        } else {
            collapsed.push(c);
            prev_dash = false;
        }
    }
    let slug = collapsed.trim_matches('-');
    format!("{}-{}", agent.to_ascii_lowercase(), slug)
}

/// Title-cased last path component, for `FocusMeta::project_name`.
fn project_name_from(cwd: &std::path::Path) -> Option<String> {
    cwd.file_name()
        .and_then(|n| n.to_str())
        .map(|s| s.to_string())
}

/// Handle `nostromo.create_focus`.
pub async fn create_focus(state: &McpSharedState, args: &Value, _pty_id: Option<&str>) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "create_focus requires the daemon-hosted MCP server" });
    };

    let agent = match args.get("agent").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return json!({ "error": "invalid_args", "detail": "missing agent" }),
    };
    let title = match args.get("title").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return json!({ "error": "invalid_args", "detail": "missing title" }),
    };
    let initial_context = args
        .get("initial_context")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    // Validate working_directory if supplied: must be an absolute, existing dir.
    let cwd: Option<PathBuf> = match args.get("working_directory").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => {
            let p = PathBuf::from(s);
            if !p.is_absolute() || !p.is_dir() {
                return json!({ "error": "invalid_working_directory", "detail": s });
            }
            Some(p)
        }
        _ => None,
    };

    let tag = derive_tag(&agent, &title);

    // Idempotent: a live focus with this tag returns its id rather than erroring.
    {
        let mgr = daemon.session_mgr.lock().unwrap();
        if mgr.has_live_session(&tag) {
            return json!({ "focus_id": tag });
        }
    }

    // Spawn the session (no remote control; daemon-hosted stream-json child).
    let spawn = {
        let mut mgr = daemon.session_mgr.lock().unwrap();
        mgr.spawn_session(
            tag.clone(),
            agent.clone(),
            title.clone(),
            cwd.clone(),
            None,
            false,
        )
    };
    if let Err(e) = spawn {
        return json!({ "error": "spawn_failed", "detail": e.to_string() });
    }

    // Initialise the pane tree to a single REPL leaf.
    {
        let mut reg = daemon.pane_registry.lock().unwrap();
        reg.init_focus(&tag);
    }

    // Seed the first turn with the initial context (best-effort).
    if let Some(ctx) = initial_context {
        let mut mgr = daemon.session_mgr.lock().unwrap();
        if let Err(e) = mgr.send_user_message(&tag, &ctx, &[]) {
            tracing::warn!(tag = %tag, "create_focus: failed to seed initial_context: {e}");
        }
    }

    // Register + broadcast the new focus.
    let meta = FocusMeta {
        tag: tag.clone(),
        display_name: title,
        agent_name: agent,
        project_name: cwd.as_deref().and_then(project_name_from),
        org: None,
        is_built_in: false,
        session_summary: None,
    };
    {
        let mut mgr = daemon.session_mgr.lock().unwrap();
        mgr.add_or_update_focus(meta.clone());
    }
    let _ = daemon.broadcast_tx.send(ServerMsg::FocusCreated { meta });
    let _ = daemon.broadcast_tx.send(ServerMsg::FocusLayout {
        tag: tag.clone(),
        tree: PaneTree::repl_leaf(),
        focused_pane: None,
    });

    json!({ "focus_id": tag })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_tag_slugifies_title() {
        assert_eq!(derive_tag("cody", "CORE-1234"), "cody-core-1234");
        assert_eq!(derive_tag("Fred", "My  Cool  Task!!"), "fred-my-cool-task");
        assert_eq!(derive_tag("cody", "  leading "), "cody-leading");
    }
}
