//! MCP tool handler: `nostromo.ask_decision`.
//!
//! Poses a decision as a modal over the window and blocks until the operator
//! answers, dismisses it, or the call times out. This is the curated-views
//! W6 "decision modal" surface — see
//! `.claude/plans/curated-agent-views-w6-decision-modals.md` in the primary
//! repo for the design.
//!
//! Deliberately **not** a content channel (R7 in the PRD): there is no
//! free-form content field anywhere in the input, only a bounded prompt, an
//! optional bounded detail string, and a closed set of labelled choices. An
//! agent that wants to show something has `nostromo.show` (a later wedge) or
//! the raw pane tools; this tool can only ask.
//!
//! Daemon-hosted only — this tool has no meaning for the standalone TUI MCP
//! server, which has no window to attach a sheet to.

use std::collections::HashSet;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{json, Value};

use crate::ipc::decisions::DecisionOutcome;
use crate::ipc::protocol::DecisionChoice;
use crate::mcp::state::McpSharedState;
use crate::mcp::tools::apply_layout::target_tag;

/// Bounds chosen to keep a decision readable in a sheet, not to be precise —
/// see the tool's `inputSchema` description in `tools/mod.rs`.
const MAX_PROMPT_LEN: usize = 2000;
const MAX_DETAIL_LEN: usize = 2000;
const MAX_LABEL_LEN: usize = 200;

/// Default and maximum `timeout_secs`. An agent blocking on a closed GUI for
/// longer than an hour is a worse failure than a refusal, so the cap is
/// enforced regardless of what the caller asks for.
const DEFAULT_TIMEOUT_SECS: u64 = 300;
const MAX_TIMEOUT_SECS: u64 = 3600;

#[derive(Deserialize)]
struct ChoiceInput {
    id: String,
    label: String,
    #[serde(default)]
    detail: Option<String>,
}

#[derive(Deserialize)]
struct AskDecisionInput {
    prompt: String,
    #[serde(default)]
    detail: Option<String>,
    choices: Vec<ChoiceInput>,
    #[serde(default)]
    context_pane_id: Option<String>,
    #[serde(default)]
    timeout_secs: Option<u64>,
}

/// Handle `nostromo.ask_decision`.
pub async fn handle(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "ask_decision requires the daemon-hosted MCP server" });
    };

    let input: AskDecisionInput = match serde_json::from_value(args.clone()) {
        Ok(v) => v,
        Err(e) => return json!({ "error": "invalid_args", "detail": e.to_string() }),
    };

    if let Some(e) = validate(&input) {
        return e;
    }

    let Some(tag) = target_tag(args, pty_id) else {
        return json!({ "error": "unidentified_caller" });
    };
    let tag = tag.to_string();

    // Fail fast rather than blocking: an agent waiting on a closed GUI for
    // the full timeout is a worse failure than an immediate refusal.
    if !daemon.decisions.lock().unwrap().has_operator() {
        return json!({ "error": "no_operator" });
    }

    let timeout_secs = input
        .timeout_secs
        .unwrap_or(DEFAULT_TIMEOUT_SECS)
        .clamp(1, MAX_TIMEOUT_SECS);

    let choices: Vec<DecisionChoice> = input
        .choices
        .into_iter()
        .map(|c| DecisionChoice {
            id: c.id,
            label: c.label,
            detail: c.detail,
        })
        .collect();

    let (request_id, rx, broadcast_now) = daemon.decisions.lock().unwrap().submit(
        tag,
        input.prompt,
        input.detail,
        choices,
        input.context_pane_id,
    );

    if let Some(msg) = broadcast_now {
        let _ = daemon.broadcast_tx.send(msg);
    }

    match tokio::time::timeout(Duration::from_secs(timeout_secs), rx).await {
        Ok(Ok(DecisionOutcome::Answered(choice_id))) => json!({ "ok": true, "choice_id": choice_id }),
        Ok(Ok(DecisionOutcome::Dismissed)) => json!({ "ok": true, "outcome": "dismissed" }),
        Ok(Ok(DecisionOutcome::Cancelled)) => json!({ "error": "cancelled" }),
        // The oneshot resolving with TimedOut before our own timeout fired is
        // not expected in practice (we're the only caller of `timeout_request`,
        // and we only call it after this future itself times out) — handled
        // anyway so every `DecisionOutcome` variant maps to a response.
        Ok(Ok(DecisionOutcome::TimedOut)) => json!({ "error": "timeout" }),
        Ok(Err(_)) => json!({ "error": "reply_channel_dropped" }),
        Err(_) => {
            let promoted = daemon.decisions.lock().unwrap().timeout_request(&request_id);
            if let Some(msg) = promoted {
                let _ = daemon.broadcast_tx.send(msg);
            }
            json!({ "error": "timeout" })
        }
    }
}

/// Build the `{ "error": "invalid_args", "detail": ... }` shape every
/// `validate` rejection returns.
fn invalid_args(detail: impl Into<String>) -> Value {
    json!({ "error": "invalid_args", "detail": detail.into() })
}

/// True iff `s` is non-empty (after trimming) and no longer than `max`. Used
/// for fields that must have real content: `prompt` and each choice's
/// `label`.
fn is_bounded_non_empty(s: &str, max: usize) -> bool {
    !s.trim().is_empty() && s.len() <= max
}

/// True iff `s` is absent, or present and no longer than `max`. Used for
/// fields that are optional but still bounded when given: `detail` and each
/// choice's `detail`.
fn is_bounded_if_present(s: &Option<String>, max: usize) -> bool {
    s.as_ref().is_none_or(|d| d.len() <= max)
}

/// Validate everything that can fail before anything is submitted to the
/// registry or broadcast. Returns `Some(error_value)` on the first violation.
fn validate(input: &AskDecisionInput) -> Option<Value> {
    if !is_bounded_non_empty(&input.prompt, MAX_PROMPT_LEN) {
        return Some(invalid_args("prompt must be 1..=2000 chars"));
    }
    if !is_bounded_if_present(&input.detail, MAX_DETAIL_LEN) {
        return Some(invalid_args("detail exceeds max length"));
    }
    if input.choices.len() < 2 {
        return Some(invalid_args("at least two choices are required"));
    }
    let mut seen_ids = HashSet::new();
    for c in &input.choices {
        if c.id.trim().is_empty() {
            return Some(invalid_args("each choice needs a non-empty id"));
        }
        if !is_bounded_non_empty(&c.label, MAX_LABEL_LEN) {
            return Some(invalid_args("each choice needs a non-empty, bounded label"));
        }
        if !is_bounded_if_present(&c.detail, MAX_DETAIL_LEN) {
            return Some(invalid_args("choice detail exceeds max length"));
        }
        if !seen_ids.insert(c.id.clone()) {
            return Some(invalid_args(format!("duplicate choice id: {}", c.id)));
        }
    }
    None
}
