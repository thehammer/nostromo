//! `nostromo.list_views` tool handler.
//!
//! Returns a JSON array describing every registered view — its id, title, pane
//! list, and a view-specific summary object drawn from live watch data.

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

/// Handle `nostromo.list_views`.
///
/// Returns an array of view descriptor objects:
/// ```json
/// [
///   {
///     "id": "perri",
///     "title": "Perri",
///     "pane_ids": ["pr_queue", "diff", "repl"],
///     "summary": { "open_pr_count": 3, "stale": false }
///   },
///   ...
/// ]
/// ```
pub async fn handle(state: &McpSharedState) -> Value {
    let views = state.views_meta.read().await.clone();

    let mut result = Vec::with_capacity(views.len());
    for view in &views {
        let summary = summary_for(view.id, state);
        result.push(json!({
            "id": view.id,
            "title": view.title,
            "pane_ids": view.pane_ids,
            "summary": summary,
        }));
    }
    Value::Array(result)
}

/// Build the view-specific `summary` object.
///
/// Views without specialised state (claudia, cody, kennedy) return `{}`.
fn summary_for(view_id: &str, state: &McpSharedState) -> Value {
    match view_id {
        "perri" => {
            let queue = state.perri_queue_rx.borrow();
            let (count, stale) = queue
                .as_ref()
                .map(|s| (s.items.len(), s.stale))
                .unwrap_or((0, false));
            json!({ "open_pr_count": count, "stale": stale })
        }
        "fred" => {
            let mailbox = state.fred_mailbox_rx.borrow();
            let unread = mailbox.as_ref().map(|s| s.unread_count).unwrap_or(0);

            let calendar = state.fred_calendar_rx.borrow();
            let today_events = calendar.as_ref().map(|s| s.events.len()).unwrap_or(0);

            json!({ "unread_email_count": unread, "today_events": today_events })
        }
        "mother" => {
            let jobs = state.mother_jobs_rx.borrow();
            let running = jobs.iter().filter(|j| j.state == "running").count();
            let awaiting = jobs.iter().filter(|j| j.state == "awaiting").count();
            let queued = jobs
                .iter()
                .filter(|j| matches!(j.state.as_str(), "queued" | "ready"))
                .count();
            json!({ "running_jobs": running, "awaiting_jobs": awaiting, "queued_jobs": queued })
        }
        "teri" => {
            let todos = state.teri_todos_rx.borrow();
            let count = todos.as_ref().map(|s| s.items.len()).unwrap_or(0);
            json!({ "todo_count": count })
        }
        _ => json!({}),
    }
}
