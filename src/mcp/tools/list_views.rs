//! `nostromo.list_views` tool handler.
//!
//! Returns a JSON array describing every registered view — its id, title, pane
//! list, and a view-specific summary object drawn from live watch data.

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;
use crate::mcp::tools::{fred, teri};

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

    let mut result = Vec::with_capacity(views.len() + 4);
    // The daemon has no TUI to fill `views_meta`; report the built-in sources
    // from the live channels instead.
    if state.daemon.is_some() {
        result.extend(builtin_entries(state));
    }
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

/// `{ name, counts, state }` for each built-in source, computed from the live
/// watch channels.
fn builtin_entries(state: &McpSharedState) -> Vec<Value> {
    let teri = teri::list_todos(state);
    let fred = fred::get_state(state);
    let (queue, perri_state) = match state.perri_queue_rx.borrow().as_ref() {
        None => (0, "loading"),
        Some(s) if s.stale => (s.items.len(), "stale"),
        Some(s) => (s.items.len(), "fresh"),
    };
    let today_events = fred["today_event_count"].clone();
    let jobs = state.mother_jobs_rx.borrow();
    let count = |states: &[&str]| jobs.iter().filter(|j| states.contains(&j.state.as_str())).count();
    vec![
        json!({
            "name": "teri",
            "counts": { "active_todos": teri["items"].as_array().map_or(0, |a| a.len()) },
            "state": teri["state"],
        }),
        json!({
            "name": "fred",
            "counts": { "unread": fred["unread_count"], "today_events": today_events },
            "state": fred["state"],
        }),
        json!({ "name": "perri", "counts": { "queue": queue }, "state": perri_state }),
        json!({
            "name": "mother",
            "counts": {
                "running": count(&["running"]),
                "queued": count(&["queued", "ready"]),
                "awaiting": count(&["awaiting"]),
                "failed": count(&["failed"]),
            },
            "state": "fresh",
        }),
    ]
}
