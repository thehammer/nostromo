//! MCP tool registry.
//!
//! Phase 1: `nostromo.get_self`
//! Phase 2: 12 new read-only introspection tools across all views.

pub mod fred;
pub mod get_self;
pub mod get_view_state;
pub mod list_views;
pub mod mother;
pub mod nostromo_meta;
pub mod perri;
pub mod teri;

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

// ── tool descriptors ─────────────────────────────────────────────────────────

/// JSON Schema descriptors for all registered MCP tools.
pub fn tool_descriptors() -> Vec<Value> {
    vec![
        // ── Phase 1 ────────────────────────────────────────────────────────
        json!({
            "name": "nostromo.get_self",
            "description": "Returns identity information about the calling Nostromo PTY session: which view and pane set the agent is running inside.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 2: global ────────────────────────────────────────────────
        json!({
            "name": "nostromo.list_views",
            "description": "Returns a list of all registered Nostromo views with their pane ids and a view-specific summary (PR counts, unread email, Mother job counts, etc.).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "nostromo.get_view_state",
            "description": "Returns the full live state snapshot for a named view.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id": { "type": "string", "description": "View id (e.g. 'perri', 'fred', 'mother', 'teri')" }
                },
                "required": ["view_id"]
            }
        }),
        json!({
            "name": "nostromo.get_worktree_info",
            "description": "Returns git repo / worktree info for the calling PTY's working directory: cwd, branch, parent repo path, and whether this is a linked worktree.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "nostromo.get_rate_limits",
            "description": "Returns the latest Claude rate-limit snapshot (5h and 7d window percentages and reset epochs).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "nostromo.get_budget_posture",
            "description": "Returns the current global budget posture (flush/normal/elevated/conservative/critical).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 2: Perri ────────────────────────────────────────────────
        json!({
            "name": "perri.list_pr_queue",
            "description": "Returns Perri's live PR review queue (all three buckets: requested, needs_review, changes_req).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "perri.get_current_pr",
            "description": "Returns the PR currently loaded in Perri's diff pane, or null if none is loaded.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "perri.get_state",
            "description": "Returns a composite Perri state: { queue, current_pr, stale }.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 2: Fred ─────────────────────────────────────────────────
        json!({
            "name": "fred.list_unread_emails",
            "description": "Returns unread emails from Fred's mailbox.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "fred.list_calendar_events",
            "description": "Returns today's calendar events (or events on a specific date).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "date": { "type": "string", "description": "Optional ISO date (YYYY-MM-DD). Omit for today's events." }
                },
                "required": []
            }
        }),
        json!({
            "name": "fred.get_state",
            "description": "Returns Fred's composite state: { unread_count, today_event_count, mailbox, calendar }.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 2: Mother ───────────────────────────────────────────────
        json!({
            "name": "mother.list_jobs",
            "description": "Returns Mother's job list. Optionally filter by status or include archived jobs.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "include_archived": { "type": "boolean", "description": "Include archived jobs (default false)" },
                    "status": { "type": "string", "description": "Filter to jobs with this state (e.g. 'running', 'awaiting', 'succeeded')" }
                },
                "required": []
            }
        }),
        json!({
            "name": "mother.get_job",
            "description": "Returns a single Mother job by id, or null if not found.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" }
                },
                "required": ["id"]
            }
        }),
        json!({
            "name": "mother.tail_log",
            "description": "Returns the last N lines of a job's log (default 50, max 500).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" },
                    "lines": { "type": "integer", "description": "Number of lines to return (default 50, max 500)" }
                },
                "required": ["id"]
            }
        }),
        json!({
            "name": "mother.peek",
            "description": "Returns a live snapshot of a running job: todo list, recent tool calls, last assistant text, and any pending await question.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" }
                },
                "required": ["id"]
            }
        }),
        json!({
            "name": "mother.get_status",
            "description": "Returns the current Mother status summary: running, queued, failed, awaiting counts.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 2: Teri ─────────────────────────────────────────────────
        json!({
            "name": "teri.list_todos",
            "description": "Returns Teri's active todo list (open, in_progress, blocked items).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
    ]
}

// ── tool dispatch ─────────────────────────────────────────────────────────────

/// Result of a tool dispatch.
pub enum ToolResult {
    /// Successful tool call; content array to embed in the MCP response.
    Ok(Vec<Value>),
    /// Tool name not recognised.
    UnknownTool(String),
}

/// Dispatch a `tools/call` request.
pub async fn dispatch(
    name: &str,
    arguments: Option<&Value>,
    state: &McpSharedState,
    pty_id: Option<&str>,
) -> ToolResult {
    let content = match name {
        // ── Phase 1 ────────────────────────────────────────────────────────
        "nostromo.get_self" => {
            get_self::handle(state, pty_id).await
        }

        // ── Phase 2: global ────────────────────────────────────────────────
        "nostromo.list_views" => {
            list_views::handle(state).await
        }
        "nostromo.get_view_state" => {
            let input = parse_args::<get_view_state::GetViewStateInput>(arguments);
            match input {
                Ok(inp) => get_view_state::handle(state, &inp).await,
                Err(e) => e,
            }
        }
        "nostromo.get_worktree_info" => {
            // Use the caller's cwd if we can look it up from their PTY identity.
            // For now, pass None (uses current process cwd) — Phase 3 can wire
            // up per-PTY cwd tracking.
            nostromo_meta::get_worktree_info(None).await
        }
        "nostromo.get_rate_limits" => {
            nostromo_meta::get_rate_limits(state)
        }
        "nostromo.get_budget_posture" => {
            nostromo_meta::get_budget_posture(state)
        }

        // ── Phase 2: Perri ────────────────────────────────────────────────
        "perri.list_pr_queue" => perri::list_pr_queue(state),
        "perri.get_current_pr" => perri::get_current_pr(state),
        "perri.get_state" => perri::get_state(state),

        // ── Phase 2: Fred ─────────────────────────────────────────────────
        "fred.list_unread_emails" => fred::list_unread_emails(state),
        "fred.list_calendar_events" => {
            let input = parse_args::<fred::CalendarEventsInput>(arguments)
                .unwrap_or_else(|_| fred::CalendarEventsInput::default());
            fred::list_calendar_events(state, &input)
        }
        "fred.get_state" => fred::get_state(state),

        // ── Phase 2: Mother ───────────────────────────────────────────────
        "mother.list_jobs" => {
            let input = parse_args::<mother::ListJobsInput>(arguments)
                .unwrap_or_else(|_| mother::ListJobsInput::default());
            mother::list_jobs(state, &input).await
        }
        "mother.get_job" => {
            match parse_args::<mother::GetJobInput>(arguments) {
                Ok(inp) => mother::get_job(state, &inp),
                Err(e) => e,
            }
        }
        "mother.tail_log" => {
            match parse_args::<mother::TailLogInput>(arguments) {
                Ok(inp) => mother::tail_log(state, &inp).await,
                Err(e) => e,
            }
        }
        "mother.peek" => {
            match parse_args::<mother::PeekInput>(arguments) {
                Ok(inp) => mother::peek(state, &inp).await,
                Err(e) => e,
            }
        }
        "mother.get_status" => mother::get_status(state),

        // ── Phase 2: Teri ─────────────────────────────────────────────────
        "teri.list_todos" => teri::list_todos(state),

        other => return ToolResult::UnknownTool(other.to_string()),
    };

    ToolResult::Ok(vec![json!({"type": "text", "text": content.to_string()})])
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Deserialize tool arguments, returning `{"error":"invalid_args"}` on failure.
fn parse_args<T: serde::de::DeserializeOwned>(arguments: Option<&Value>) -> Result<T, Value> {
    let v = arguments.cloned().unwrap_or(Value::Object(Default::default()));
    serde_json::from_value(v).map_err(|e| {
        json!({ "error": "invalid_args", "detail": e.to_string() })
    })
}
