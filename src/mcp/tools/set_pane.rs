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
use crate::ipc::protocol::{PaneContentWire, PrListItem, ServerMsg};
use crate::mcp::{
    command::{McpCommand, PaneContent},
    state::McpSharedState,
};

const COMMAND_TIMEOUT_SECS: u64 = 5;

/// The full set of `PaneContentWire` discriminator names. Used by
/// `parse_pane_content`'s `"json_snapshot"` arm to catch a classic mistake:
/// nesting an already-typed content payload (e.g. `{ kind: "pr_list", items:
/// [...] }`) inside `json_snapshot`'s `value` instead of using `content.type`
/// directly. The GUI has no native renderer for a `json_snapshot`-wrapped
/// `pr_list`/`text`/etc. — it silently falls through to the generic key/value
/// JSON viewer, which reads as broken rather than erroring.
const KNOWN_CONTENT_KINDS: &[&str] = &["text", "json_snapshot", "pr_list", "loading", "error"];

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
            PaneContent::Text(t)          => PaneContentWire::Text { text: t },
            PaneContent::JsonSnapshot(v)  => PaneContentWire::JsonSnapshot { value: v },
            PaneContent::PrList(items)    => PaneContentWire::PrList { items },
            PaneContent::Loading          => PaneContentWire::Loading,
            PaneContent::Error(msg)       => PaneContentWire::Error { message: msg },
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

    // Accept both "type" (MCP input convention) and "kind" (wire convention) so
    // agents can use either discriminator key without knowing the internal split.
    let type_str = v.get("type")
        .or_else(|| v.get("kind"))
        .and_then(|t| t.as_str())
        .unwrap_or("text");
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

            // Guard against wrapping an already-typed content payload inside
            // json_snapshot instead of using content.type/content.kind
            // directly — see KNOWN_CONTENT_KINDS doc comment.
            if let Some(nested_kind) = snap.get("kind").and_then(|k| k.as_str()) {
                if KNOWN_CONTENT_KINDS.contains(&nested_kind) {
                    return Err(format!(
                        "json_snapshot.value has its own \"kind\": \"{nested_kind}\" field \
                         matching a real content type — this looks like a mis-nested content \
                         payload. Use `content.type: \"{nested_kind}\"` (with its own fields, \
                         e.g. `items` for pr_list) directly instead of wrapping it in \
                         json_snapshot, or the GUI will render it as inert JSON instead of the \
                         native view."
                    ));
                }
            }

            Ok(PaneContent::JsonSnapshot(snap))
        }
        "pr_list" => {
            let items_raw = v
                .get("items")
                .and_then(|i| i.as_array())
                .cloned()
                .unwrap_or_default();

            let mut items = Vec::with_capacity(items_raw.len());
            for (idx, raw) in items_raw.iter().enumerate() {
                let item: PrListItem = serde_json::from_value(raw.clone()).map_err(|e| {
                    format!("unsupported_payload: items[{idx}] missing required field: {e}")
                })?;
                items.push(item);
            }
            Ok(PaneContent::PrList(items))
        }
        "loading" => Ok(PaneContent::Loading),
        "error" => {
            let msg = v.get("message")
                .or_else(|| v.get("text"))
                .and_then(|m| m.as_str())
                .unwrap_or("An error occurred")
                .to_string();
            Ok(PaneContent::Error(msg))
        }
        other => Err(format!("unknown content type: {other}")),
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_snapshot_wrapping_pr_list_is_rejected() {
        let content = json!({
            "type": "json_snapshot",
            "value": {
                "kind": "pr_list",
                "items": [
                    { "repo": "acme/web", "number": 1, "title": "t", "author": "a",
                      "bucket": "requested", "ci_state": "success", "url": "https://x" }
                ]
            }
        });
        let err = parse_pane_content(Some(&content)).unwrap_err();
        assert!(
            err.contains("pr_list"),
            "error should name the mis-nested kind: {err}"
        );
        assert!(
            err.contains("content.type"),
            "error should point the caller at the fix: {err}"
        );
    }

    #[test]
    fn json_snapshot_wrapping_text_is_rejected() {
        let content = json!({
            "type": "json_snapshot",
            "value": { "kind": "text", "text": "hi" }
        });
        let err = parse_pane_content(Some(&content)).unwrap_err();
        assert!(err.contains("text"));
    }

    #[test]
    fn json_snapshot_with_ordinary_data_is_accepted() {
        // A real json_snapshot use case: arbitrary structured data with no
        // "kind" field at all, or one that isn't a recognised content type.
        let content = json!({
            "type": "json_snapshot",
            "value": { "queue_depth": 12, "last_run": "2026-07-30" }
        });
        let parsed = parse_pane_content(Some(&content)).unwrap();
        assert!(matches!(parsed, PaneContent::JsonSnapshot(_)));
    }

    #[test]
    fn json_snapshot_with_unrelated_kind_field_is_accepted() {
        // "kind" that doesn't match any real PaneContentWire variant is just
        // ordinary data, not a mis-nesting mistake — don't false-positive.
        let content = json!({
            "type": "json_snapshot",
            "value": { "kind": "widget", "count": 3 }
        });
        let parsed = parse_pane_content(Some(&content)).unwrap();
        assert!(matches!(parsed, PaneContent::JsonSnapshot(_)));
    }

    #[test]
    fn json_snapshot_of_bare_scalar_is_accepted() {
        let content = json!({ "type": "json_snapshot", "value": "just a string" });
        let parsed = parse_pane_content(Some(&content)).unwrap();
        assert!(matches!(parsed, PaneContent::JsonSnapshot(_)));
    }

    #[test]
    fn pr_list_content_type_still_works_directly() {
        let content = json!({
            "type": "pr_list",
            "items": [
                { "repo": "acme/web", "number": 1, "title": "t", "author": "a",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" }
            ]
        });
        let parsed = parse_pane_content(Some(&content)).unwrap();
        assert!(matches!(parsed, PaneContent::PrList(items) if items.len() == 1));
    }
}
