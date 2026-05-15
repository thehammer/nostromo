//! Fred-scoped MCP tool handlers.
//!
//! ## Tools
//! - `fred.list_unread_emails()` — unread items from `fred_mailbox_rx`
//! - `fred.list_calendar_events({ date? })` — events from `fred_calendar_rx`
//! - `fred.get_state()` — composite mailbox + calendar summary

use chrono::NaiveDate;
use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

/// Input for `fred.list_calendar_events`.
#[derive(serde::Deserialize, Default)]
pub struct CalendarEventsInput {
    /// Optional ISO date to filter events.  Omit for today's events.
    pub date: Option<String>,
}

/// Handle `fred.list_unread_emails()`.
///
/// Returns an array of unread `MailboxItem`s.  Fields match `MailboxItem`.
pub fn list_unread_emails(state: &McpSharedState) -> Value {
    let borrow = state.fred_mailbox_rx.borrow();
    match borrow.as_ref() {
        Some(snap) => {
            let unread: Vec<_> = snap.items.iter().filter(|i| !i.is_read).collect();
            serde_json::to_value(&unread).unwrap_or_else(|e| {
                json!({ "error": "serialization_failed", "detail": e.to_string() })
            })
        }
        None => Value::Array(vec![]),
    }
}

/// Handle `fred.list_calendar_events({ date? })`.
///
/// - If `date` is omitted, returns all events in today's calendar snapshot.
/// - If `date` is provided, parses it as `YYYY-MM-DD` and filters to events
///   whose `start` date matches.  Bad dates return `{"error": "bad_date"}`.
pub fn list_calendar_events(state: &McpSharedState, input: &CalendarEventsInput) -> Value {
    let target_date: Option<NaiveDate> = match &input.date {
        Some(d) => match NaiveDate::parse_from_str(d, "%Y-%m-%d") {
            Ok(nd) => Some(nd),
            Err(_) => return json!({ "error": "bad_date", "provided": d }),
        },
        None => None,
    };

    let borrow = state.fred_calendar_rx.borrow();
    match borrow.as_ref() {
        Some(snap) => {
            let events: Vec<_> = snap
                .events
                .iter()
                .filter(|ev| {
                    if let Some(td) = target_date {
                        ev.start
                            .map(|s| s.date_naive() == td)
                            .unwrap_or(false)
                    } else {
                        true
                    }
                })
                .collect();
            serde_json::to_value(&events).unwrap_or_else(|e| {
                json!({ "error": "serialization_failed", "detail": e.to_string() })
            })
        }
        None => Value::Array(vec![]),
    }
}

/// Handle `fred.get_state()`.
///
/// Returns `{ unread_count, today_event_count, mailbox: [...], calendar: [...] }`.
pub fn get_state(state: &McpSharedState) -> Value {
    let mailbox_borrow = state.fred_mailbox_rx.borrow();
    let (unread_count, mailbox_items) = match mailbox_borrow.as_ref() {
        Some(snap) => (
            snap.unread_count,
            serde_json::to_value(&snap.items).unwrap_or(Value::Array(vec![])),
        ),
        None => (0, Value::Array(vec![])),
    };
    drop(mailbox_borrow);

    let calendar_borrow = state.fred_calendar_rx.borrow();
    let (today_event_count, calendar_events) = match calendar_borrow.as_ref() {
        Some(snap) => (
            snap.events.len(),
            serde_json::to_value(&snap.events).unwrap_or(Value::Array(vec![])),
        ),
        None => (0, Value::Array(vec![])),
    };
    drop(calendar_borrow);

    json!({
        "unread_count": unread_count,
        "today_event_count": today_event_count,
        "mailbox": mailbox_items,
        "calendar": calendar_events,
    })
}
