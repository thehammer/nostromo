//! Mother-scoped MCP tool handlers.
//!
//! ## Tools
//! - `mother.list_jobs({ include_archived?, status? })` — jobs from `mother_jobs_rx`
//! - `mother.get_job({ id })` — single job by id
//! - `mother.tail_log({ id, lines? })` — last N lines of a job's log
//! - `mother.peek({ id })` — `PeekSnapshot` for a running job
//! - `mother.get_status()` — latest `MotherStatus`

use serde_json::{json, Value};

use crate::{mcp::state::McpSharedState, mother};

/// Maximum lines returned by `mother.tail_log`.
const MAX_TAIL_LINES: u32 = 500;

// ── input types ───────────────────────────────────────────────────────────────

#[derive(serde::Deserialize, Default)]
pub struct ListJobsInput {
    #[serde(default)]
    pub include_archived: bool,
    pub status: Option<String>,
}

#[derive(serde::Deserialize)]
pub struct GetJobInput {
    pub id: String,
}

#[derive(serde::Deserialize)]
pub struct TailLogInput {
    pub id: String,
    #[serde(default)]
    pub lines: Option<u32>,
}

#[derive(serde::Deserialize)]
pub struct PeekInput {
    pub id: String,
}

// ── handlers ─────────────────────────────────────────────────────────────────

/// Handle `mother.list_jobs({ include_archived?, status? })`.
pub async fn list_jobs(state: &McpSharedState, input: &ListJobsInput) -> Value {
    let jobs = if input.include_archived {
        // Fetch the full list (including archived) directly from mother.
        match mother::list_jobs().await {
            Ok(j) => j,
            Err(e) => {
                return json!({ "error": "mother_list_failed", "detail": e.to_string() })
            }
        }
    } else {
        state.mother_jobs_rx.borrow().clone()
    };

    let filtered: Vec<_> = jobs
        .iter()
        .filter(|j| {
            input
                .status
                .as_ref()
                .map(|s| j.state == *s)
                .unwrap_or(true)
        })
        .collect();

    serde_json::to_value(&filtered).unwrap_or_else(|e| {
        json!({ "error": "serialization_failed", "detail": e.to_string() })
    })
}

/// Handle `mother.get_job({ id })`.
pub fn get_job(state: &McpSharedState, input: &GetJobInput) -> Value {
    let borrow = state.mother_jobs_rx.borrow();
    match borrow.iter().find(|j| j.id == input.id) {
        Some(job) => serde_json::to_value(job).unwrap_or_else(|e| {
            json!({ "error": "serialization_failed", "detail": e.to_string() })
        }),
        None => Value::Null,
    }
}

/// Handle `mother.tail_log({ id, lines? })`.
///
/// Returns the last `lines` lines of the job's log as a string.
/// Bounded at [`MAX_TAIL_LINES`].
pub async fn tail_log(_state: &McpSharedState, input: &TailLogInput) -> Value {
    let n = input
        .lines
        .unwrap_or(50)
        .min(MAX_TAIL_LINES) as usize;

    match mother::tail_log(&input.id, n).await {
        Ok(text) => json!({ "id": input.id, "lines": n, "log": text }),
        Err(e) => json!({ "error": "tail_failed", "detail": e.to_string() }),
    }
}

/// Handle `mother.peek({ id })`.
pub async fn peek(_state: &McpSharedState, input: &PeekInput) -> Value {
    match mother::peek(&input.id).await {
        Ok(snap) => serde_json::to_value(&snap).unwrap_or_else(|e| {
            json!({ "error": "serialization_failed", "detail": e.to_string() })
        }),
        Err(e) => json!({ "error": "peek_failed", "detail": e.to_string() }),
    }
}

/// Handle `mother.get_status()`.
pub fn get_status(state: &McpSharedState) -> Value {
    match state.mother_status_rx.borrow().as_ref() {
        Some(status) => serde_json::to_value(status).unwrap_or_else(|e| {
            json!({ "error": "serialization_failed", "detail": e.to_string() })
        }),
        None => Value::Null,
    }
}
