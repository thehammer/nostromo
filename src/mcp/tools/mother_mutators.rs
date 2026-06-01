//! MCP tool handlers for Mother job-control mutations.
//!
//! ## Tools
//! - `mother.enqueue_job({ plan_path })`
//! - `mother.cancel_job({ id })`
//! - `mother.archive_job({ id })`
//! - `mother.resume_job({ id, answer })`

use std::path::PathBuf;

use serde_json::{json, Value};
use tokio::sync::oneshot;

use crate::event::AppEvent;
use crate::mcp::{command::McpCommand, state::McpSharedState};

const COMMAND_TIMEOUT_SECS: u64 = 5;

// ── handlers ─────────────────────────────────────────────────────────────────

/// Handle `mother.enqueue_job({ plan_path })`.
pub async fn enqueue_job(state: &McpSharedState, args: &Value) -> Value {
    let plan_path = match args.get("plan_path").and_then(|v| v.as_str()) {
        Some(s) => PathBuf::from(s),
        None => return json!({ "error": "invalid_args", "detail": "missing plan_path" }),
    };

    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::MotherEnqueue {
        plan_path,
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
        Ok(Ok(Ok(lite))) => serde_json::to_value(&lite)
            .unwrap_or_else(|_| json!({ "error": "serialization_failed" })),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `mother.cancel_job({ id })`.
pub async fn cancel_job(state: &McpSharedState, args: &Value) -> Value {
    let job_id = match args.get("id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing id" }),
    };

    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::MotherCancel { job_id, reply: tx };
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

/// Handle `mother.archive_job({ id })`.
pub async fn archive_job(state: &McpSharedState, args: &Value) -> Value {
    let job_id = match args.get("id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing id" }),
    };

    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::MotherArchive { job_id, reply: tx };
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

/// Handle `mother.retry_job({ id })`.
pub async fn retry_job(state: &McpSharedState, args: &Value) -> Value {
    let job_id = match args.get("id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing id" }),
    };

    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::MotherRetry { job_id, reply: tx };
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

/// Handle `mother.resume_job({ id, answer })`.
pub async fn resume_job(state: &McpSharedState, args: &Value) -> Value {
    let job_id = match args.get("id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing id" }),
    };
    let answer = match args.get("answer").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing answer" }),
    };

    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::MotherResume {
        job_id,
        answer,
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
