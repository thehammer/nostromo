//! MCP tool handlers for pane mutation tools.
//!
//! ## Tools
//! - `nostromo.set_pane_content({ view_id, pane_id, content })` — write content to a pane
//! - `nostromo.set_pane_focus({ view_id, pane_id })` — focus a pane within a view
//! - `nostromo.set_pane_layout({ view_id, ratios })` — update split ratios

use serde_json::{json, Value};
use tokio::sync::oneshot;
use tracing::warn;

use crate::event::AppEvent;
use crate::ipc::protocol::{PaneContentWire, ServerMsg};
use crate::mcp::{
    command::{McpCommand, PaneContent},
    state::McpSharedState,
};

const COMMAND_TIMEOUT_SECS: u64 = 5;

// ── handlers ─────────────────────────────────────────────────────────────────

/// Handle `nostromo.set_pane_content`.
pub async fn set_pane_content(state: &McpSharedState, args: &Value) -> Value {
    let view_id = match args.get("view_id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing view_id" }),
    };
    let pane_id = match args.get("pane_id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing pane_id" }),
    };

    // Accept content as: { "type": "text", "text": "..." } or { "type": "json_snapshot", "value": ... }
    let content = match parse_pane_content(args.get("content")) {
        Ok(c) => c,
        Err(e) => return json!({ "error": "invalid_args", "detail": e }),
    };

    // ── daemon-hosted path ──────────────────────────────────────────────────
    // Content is decoupled from layout geometry: broadcast a `PaneContent`
    // message that carries no ratios, so an operator's drag-resize survives.
    if let Some(daemon) = &state.daemon {
        let wire = match content {
            PaneContent::Text(t) => PaneContentWire::Text { text: t },
            PaneContent::JsonSnapshot(v) => PaneContentWire::JsonSnapshot { value: v },
        };
        let _ = daemon.broadcast_tx.send(ServerMsg::PaneContent {
            tag: view_id,
            pane_id,
            content: wire,
        });
        return json!({ "ok": true });
    }

    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::SetPaneContent {
        view_id,
        pane_id,
        content,
        reply: tx,
    };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        warn!("set_pane_content: event_tx closed");
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `nostromo.set_pane_focus`.
pub async fn set_pane_focus(state: &McpSharedState, args: &Value) -> Value {
    let view_id = match args.get("view_id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing view_id" }),
    };
    let pane_id = match args.get("pane_id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing pane_id" }),
    };

    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::SetPaneFocus {
        view_id,
        pane_id,
        reply: tx,
    };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `nostromo.set_pane_layout`.
pub async fn set_pane_layout(state: &McpSharedState, args: &Value) -> Value {
    let view_id = match args.get("view_id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing view_id" }),
    };
    let ratios = match args.get("ratios") {
        Some(r) => r.clone(),
        None => return json!({ "error": "invalid_args", "detail": "missing ratios" }),
    };

    // ── daemon-hosted path ──────────────────────────────────────────────────
    // Re-declare the focus's layout. The `ratios` payload may be a flat
    // `{ pane_id: ratio }` map (legacy sugar) or a full pane tree (B3); the
    // registry normalises both. Broadcasts a structural `FocusLayout`.
    if let Some(daemon) = &state.daemon {
        let result = {
            let mut reg = daemon.pane_registry.lock().unwrap();
            reg.set_layout(&view_id, &ratios)
        };
        return match result {
            Ok(tree) => {
                let _ = daemon.broadcast_tx.send(ServerMsg::FocusLayout {
                    tag: view_id,
                    tree,
                    focused_pane: None,
                });
                json!({ "ok": true })
            }
            Err(e) => json!({ "error": e.code() }),
        };
    }

    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::SetPaneLayout {
        view_id,
        ratios,
        reply: tx,
    };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn parse_pane_content(v: Option<&Value>) -> Result<PaneContent, String> {
    let v = match v {
        Some(v) => v,
        None => return Err("missing content".into()),
    };

    // Accept either a structured object or a bare string (shorthand for text).
    if let Some(s) = v.as_str() {
        return Ok(PaneContent::Text(s.to_string()));
    }

    let type_str = v.get("type").and_then(|t| t.as_str()).unwrap_or("text");
    match type_str {
        "text" => {
            let text = v
                .get("text")
                .or_else(|| v.get("value"))
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string();
            Ok(PaneContent::Text(text))
        }
        "json_snapshot" => {
            let snap = v
                .get("value")
                .or_else(|| v.get("snapshot"))
                .cloned()
                .unwrap_or(Value::Null);
            Ok(PaneContent::JsonSnapshot(snap))
        }
        other => Err(format!("unknown content type: {other}")),
    }
}
