//! Adapter from Teri's todo snapshot (`teri_todos.rs`) to work items.
//!
//! State mapping (never an empty list for a broken store):
//! - no database      -> `not_configured`
//! - read failed, last items kept -> `stale` (items stay visible)
//! - read failed, nothing to show -> `error`
//! - healthy, no active todos     -> `empty`
//! - otherwise                    -> `fresh`

use chrono::{Datelike, NaiveDate};

use crate::data::teri_todos::{TeriTodo, TeriTodosSnapshot};

use super::model::{
    Link, Priority, SourceState, SourceStatus, WorkDetail, WorkError, WorkItem, WorkSource,
};

/// Reason shown when `~/.teri/teri.db` does not exist.
pub const NOT_CONFIGURED_REASON: &str = "Teri's todo store ~/.teri/teri.db not found";

/// Map a snapshot to the source status and its items (in the snapshot's order).
pub fn adapt(snap: &TeriTodosSnapshot) -> (SourceStatus, Vec<WorkItem>) {
    let items: Vec<WorkItem> = snap.items.iter().map(to_work_item).collect();
    let (state, reason) = if snap.not_configured {
        (SourceState::NotConfigured, Some(NOT_CONFIGURED_REASON.to_string()))
    } else if let Some(error) = &snap.error {
        let why = format!("Couldn't read Teri's todo store: {error}");
        if snap.stale && !items.is_empty() {
            (SourceState::Stale, Some(format!("{why}; showing the last good list")))
        } else {
            (SourceState::Error, Some(why))
        }
    } else if snap.stale {
        (SourceState::Stale, Some("Teri's todo store could not be read; showing the last good list".into()))
    } else if items.is_empty() {
        (SourceState::Empty, None)
    } else {
        (SourceState::Fresh, None)
    };
    let items = if snap.not_configured { Vec::new() } else { items };
    let status = SourceStatus {
        source: WorkSource::Todos,
        state,
        updated_at: snap.generated_at,
        reason,
        retry_at: None,
        count: items.len(),
        group_errors: Vec::new(),
    };
    (status, items)
}

fn to_work_item(todo: &TeriTodo) -> WorkItem {
    let rank = todo.priority.clamp(1, 5);
    let mut search_text = todo.title.clone();
    if let Some(body) = todo.body.as_deref().filter(|b| !b.is_empty()) {
        search_text.push('\n');
        search_text.push_str(body);
    }
    if let Some(key) = &todo.jira_key {
        search_text.push('\n');
        search_text.push_str(key);
    }
    WorkItem {
        id: format!("todo:{}", todo.id),
        source: WorkSource::Todos,
        kind: "todo".into(),
        title: todo.title.clone(),
        repo: None,
        project: None,
        status: Some(todo.status.clone()),
        status_category: None,
        priority: Some(Priority { label: format!("P{rank}"), rank }),
        severity: None,
        environment: None,
        created_at: None,
        updated_at: None,
        due: todo.due_date.as_deref().and_then(parse_due),
        url: None,
        path: None,
        metrics: Default::default(),
        linked: todo.jira_key.iter().cloned().collect(),
        search_text,
        sent: Vec::new(),
    }
}

/// `yyyy-MM-dd`, tolerating a trailing time part. Anything else is "no due date".
fn parse_due(raw: &str) -> Option<NaiveDate> {
    let date_part = raw.trim().get(..10)?;
    NaiveDate::parse_from_str(date_part, "%Y-%m-%d").ok()
}

/// Detail for `todo:<id>` from the latest snapshot. `jira_site` (a host name
/// such as `example.atlassian.net`) makes the linked Jira key openable.
pub fn detail(
    snap: &TeriTodosSnapshot,
    item_id: &str,
    jira_site: Option<&str>,
) -> Result<WorkDetail, WorkError> {
    let todo = item_id
        .strip_prefix("todo:")
        .and_then(|raw| raw.parse::<i64>().ok())
        .and_then(|id| snap.items.iter().find(|t| t.id == id))
        .ok_or_else(|| WorkError::new("unknown_item", "That todo is no longer active"))?;

    let mut fields = vec![
        ("Status".to_string(), humanize_status(&todo.status)),
        ("Priority".to_string(), format!("P{}", todo.priority.clamp(1, 5))),
    ];
    if let Some(due) = todo.due_date.as_deref().and_then(parse_due) {
        fields.push(("Due".to_string(), format!("{due} ({})", weekday_short(due))));
    }
    let mut links = Vec::new();
    if let Some(key) = &todo.jira_key {
        fields.push(("Jira".to_string(), key.clone()));
        if let Some(site) = jira_site.filter(|s| !s.is_empty()) {
            links.push(Link {
                label: format!("Open {key} in Jira"),
                url: format!("https://{site}/browse/{key}"),
            });
        }
    }
    Ok(WorkDetail {
        item_id: item_id.to_string(),
        title: todo.title.clone(),
        fields,
        markdown: todo.body.clone().unwrap_or_default(),
        files: Vec::new(),
        links,
    })
}

fn humanize_status(raw: &str) -> String {
    match raw {
        "in_progress" => "In progress".into(),
        "open" => "Open".into(),
        "blocked" => "Blocked".into(),
        other => other.replace('_', " "),
    }
}

fn weekday_short(date: NaiveDate) -> String {
    date.weekday().to_string()
}
