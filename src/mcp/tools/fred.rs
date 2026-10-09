//! Fred-scoped MCP tool handlers.
//!
//! ## Tools
//! - `fred.list_unread_emails()` — unread items from `fred_mailbox_rx`
//! - `fred.list_calendar_events({ date? })` — events from `fred_calendar_rx`
//! - `fred.get_state()` — composite mailbox + calendar summary

use chrono::{DateTime, NaiveDate, Utc};
use serde_json::{json, Value};

use crate::data::{fred_calendar::CalendarSnapshot, fred_mailbox::MailboxSnapshot};
use crate::mcp::state::McpSharedState;
use crate::mcp::tools::teri::source_state;

/// Input for `fred.list_calendar_events`.
#[derive(serde::Deserialize, Default)]
pub struct CalendarEventsInput {
    /// Optional ISO date to filter events.  Omit for today's events.
    pub date: Option<String>,
}

/// State of a Fred source, derived from its snapshot.
struct SourceView {
    state: &'static str,
    updated_at: Option<DateTime<Utc>>,
    reason: Option<String>,
    auth: Option<Value>,
}

fn mailbox_view(snap: Option<&MailboxSnapshot>) -> SourceView {
    let Some(snap) = snap else {
        return SourceView { state: source_state::LOADING, updated_at: None, reason: None, auth: None };
    };
    if let Some(p) = &snap.auth_prompt {
        // Only the sign-in prompt — never a token.
        return SourceView {
            state: source_state::UNAUTHENTICATED,
            updated_at: snap.generated_at,
            reason: Some("Microsoft sign-in required".into()),
            auth: Some(json!({
                "verification_uri": p.verification_uri,
                "user_code": p.user_code,
                "expires_at": p.expires_at,
            })),
        };
    }
    SourceView {
        state: source_state::derive(snap.stale, snap.error.as_deref(), snap.items.is_empty()),
        updated_at: snap.generated_at,
        reason: snap.error.clone(),
        auth: None,
    }
}

fn calendar_view(snap: Option<&CalendarSnapshot>) -> SourceView {
    let Some(snap) = snap else {
        return SourceView { state: source_state::LOADING, updated_at: None, reason: None, auth: None };
    };
    SourceView {
        state: source_state::derive(snap.stale, snap.error.as_deref(), snap.events.is_empty()),
        updated_at: None,
        reason: snap.error.clone(),
        auth: None,
    }
}

/// How bad a state is, for picking the composite `fred.get_state` state.
fn severity(state: &str) -> u8 {
    match state {
        source_state::UNAUTHENTICATED => 4,
        source_state::ERROR => 3,
        source_state::STALE => 2,
        source_state::LOADING => 1,
        _ => 0,
    }
}

fn ser<T: serde::Serialize>(v: &T) -> Value {
    serde_json::to_value(v)
        .unwrap_or_else(|e| json!({ "error": "serialization_failed", "detail": e.to_string() }))
}

/// Handle `fred.list_unread_emails()`.
///
/// Returns `{ state, updated_at, reason?, auth?, unread_count, items }`.
/// `items` are the unread `MailboxItem`s. A fetch that failed or has not
/// completed is reported through `state`, never as an empty list alone.
pub fn list_unread_emails(state: &McpSharedState) -> Value {
    let borrow = state.fred_mailbox_rx.borrow();
    let view = mailbox_view(borrow.as_ref());
    let (unread_count, items) = match borrow.as_ref() {
        Some(snap) => (snap.unread_count, snap.items.iter().filter(|i| !i.is_read).collect()),
        None => (0, Vec::new()),
    };
    let mut out = json!({
        "state": view.state,
        "updated_at": view.updated_at,
        "unread_count": unread_count,
        "items": ser(&items),
    });
    insert_reason_auth(&mut out, &view);
    out
}

/// Handle `fred.list_calendar_events({ date? })`.
///
/// - If `date` is omitted, returns all events in today's calendar snapshot.
/// - If `date` is provided, parses it as `YYYY-MM-DD` and filters to events
///   whose `start` date matches.  Bad dates return `{"error": "bad_date"}`.
///
/// Returns `{ state, updated_at, reason?, events }`.
pub fn list_calendar_events(state: &McpSharedState, input: &CalendarEventsInput) -> Value {
    let target_date: Option<NaiveDate> = match &input.date {
        Some(d) => match NaiveDate::parse_from_str(d, "%Y-%m-%d") {
            Ok(nd) => Some(nd),
            Err(_) => return json!({ "error": "bad_date", "provided": d }),
        },
        None => None,
    };

    let borrow = state.fred_calendar_rx.borrow();
    let view = calendar_view(borrow.as_ref());
    let events: Vec<_> = borrow
        .as_ref()
        .map(|snap| {
            snap.events
                .iter()
                .filter(|ev| match target_date {
                    Some(td) => ev.start.map(|s| s.date_naive() == td).unwrap_or(false),
                    None => true,
                })
                .collect()
        })
        .unwrap_or_default();
    let mut out = json!({
        "state": view.state,
        "updated_at": view.updated_at,
        "events": ser(&events),
    });
    insert_reason_auth(&mut out, &view);
    out
}

/// Handle `fred.get_state()`.
///
/// Returns `{ state, updated_at, reason?, auth?, unread_count,
/// today_event_count, mailbox, calendar, mailbox_state, calendar_state }`.
/// `state` is the worse of the mailbox and calendar states.
pub fn get_state(state: &McpSharedState) -> Value {
    let mailbox_borrow = state.fred_mailbox_rx.borrow();
    let mailbox = mailbox_view(mailbox_borrow.as_ref());
    let (unread_count, mailbox_items) = match mailbox_borrow.as_ref() {
        Some(snap) => (snap.unread_count, ser(&snap.items)),
        None => (0, Value::Array(vec![])),
    };
    drop(mailbox_borrow);

    let calendar_borrow = state.fred_calendar_rx.borrow();
    let calendar = calendar_view(calendar_borrow.as_ref());
    let (today_event_count, calendar_events) = match calendar_borrow.as_ref() {
        Some(snap) => (snap.events.len(), ser(&snap.events)),
        None => (0, Value::Array(vec![])),
    };
    drop(calendar_borrow);

    let (mailbox_state, calendar_state) = (mailbox.state, calendar.state);
    let worst = if severity(calendar_state) > severity(mailbox_state) { calendar } else { mailbox };
    let composite = if severity(worst.state) == 0 && mailbox_state != calendar_state {
        // fresh + empty: something is there.
        source_state::FRESH
    } else {
        worst.state
    };
    let mut out = json!({
        "state": composite,
        "updated_at": worst.updated_at,
        "unread_count": unread_count,
        "today_event_count": today_event_count,
        "mailbox": mailbox_items,
        "calendar": calendar_events,
        "mailbox_state": mailbox_state,
        "calendar_state": calendar_state,
    });
    insert_reason_auth(&mut out, &worst);
    out
}

fn insert_reason_auth(out: &mut Value, view: &SourceView) {
    let Some(obj) = out.as_object_mut() else { return };
    if let Some(r) = &view.reason {
        obj.insert("reason".into(), json!(r));
    }
    if let Some(a) = &view.auth {
        obj.insert("auth".into(), a.clone());
    }
}
