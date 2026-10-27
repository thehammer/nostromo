//! Work-item data model shared by the daemon, the IPC wire and (mirrored in
//! `Data/WorkModels.swift`) the Mac app. Field names are snake_case on the
//! wire. Every optional field is `#[serde(default)]` so additive changes never
//! break an older decoder.

use std::collections::BTreeMap;

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

/// Where a work item comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkSource {
    Todos,
    RepoDocs,
    Jira,
    Sentry,
}

impl WorkSource {
    /// The snake_case wire name (also used in retain keys).
    pub fn as_str(self) -> &'static str {
        match self {
            WorkSource::Todos => "todos",
            WorkSource::RepoDocs => "repo_docs",
            WorkSource::Jira => "jira",
            WorkSource::Sentry => "sentry",
        }
    }
}

/// Health of one source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SourceState {
    /// No fetch has completed yet (also what an absent `state` field means).
    #[default]
    Loading,
    Fresh,
    Stale,
    NotConfigured,
    Unauthenticated,
    RateLimited,
    Empty,
    Error,
}

impl SourceState {
    /// How bad a state is, for picking the worst of several sources.
    pub fn severity(self) -> u8 {
        match self {
            SourceState::Unauthenticated => 5,
            SourceState::NotConfigured => 4,
            SourceState::Error => 3,
            SourceState::RateLimited | SourceState::Stale => 2,
            SourceState::Loading => 1,
            SourceState::Fresh | SourceState::Empty => 0,
        }
    }
}

/// A per-group failure inside a source (e.g. one repo's docs failed to scan).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupError {
    pub group: String,
    pub reason: String,
}

/// Status of one work source. `reason` is plain English and never a secret.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceStatus {
    pub source: WorkSource,
    pub state: SourceState,
    /// Last successful fetch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// When a `rate_limited` / backoff source will next try.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<DateTime<Utc>>,
    /// Items currently held.
    #[serde(default)]
    pub count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub group_errors: Vec<GroupError>,
    /// True only when the published list is known to be the whole list: nothing
    /// cut at a cap, no unreadable or skipped item, no partial scan. A consumer
    /// that infers "done" from an item's absence (T4's `recompute_done_since`)
    /// must require this, because `state` stays `fresh` (with a `reason` note)
    /// for a partial list.
    ///
    /// Absent on the wire (an older sender) decodes as `false`, deliberately:
    /// "completeness unknown" must never read as "complete". It is always sent.
    #[serde(default)]
    pub complete: bool,
}

/// Priority with a sortable rank (1 = most urgent).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Priority {
    pub label: String,
    pub rank: u8,
}

/// Records that a work item was sent to an agent / Mother job.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SentMarker {
    /// `"focus"` or `"mother_job"`.
    pub kind: String,
    pub target_id: String,
    pub label: String,
    pub created_at: DateTime<Utc>,
    /// Identifies the focus this marker was recorded for (a `"focus"` marker
    /// only). Tags are reused once a focus closes; the nonce lets a marker
    /// tell "my focus" from "a later focus that took the tag".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nonce: Option<String>,
}

/// Sentry assignee buckets Teri's agents never see: not in `teri.list_work_items`,
/// not through `teri.get_work_item`, and not pickable. The Sentry tab still shows
/// them under All. To hide older unassigned issues from agents too, add
/// `ASSIGNEE_UNASSIGNED_OLDER` here.
pub const AGENT_HIDDEN_SENTRY_ASSIGNEES: &[&str] = &[super::sentry::ASSIGNEE_OTHER];

/// May an agent (the MCP tools and Teri's picks) see this item? False for a Sentry
/// issue in one of [`AGENT_HIDDEN_SENTRY_ASSIGNEES`]. The hub itself and the app
/// keep every item, so hiding never reads as the work being done.
pub fn agent_visible(item: &WorkItem) -> bool {
    !(item.source == WorkSource::Sentry
        && item
            .assignee
            .as_deref()
            .is_some_and(|a| AGENT_HIDDEN_SENTRY_ASSIGNEES.contains(&a)))
}

/// One item in the Teri work list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkItem {
    /// `todo:<id>` | `doc:<repo>:<path relative to .claude/>` | `jira:<KEY>` | `sentry:<issue id>`.
    pub id: String,
    pub source: WorkSource,
    pub kind: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    /// Jira: `in_progress` | `to_do` | `other`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status_category: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<Priority>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub severity: Option<String>,
    /// Sentry: `"production"` when the production search returned the issue
    /// (an event in the last 14 days), otherwise unset. Unset means "not seen in
    /// production in the window", not "non-production".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<String>,
    /// Sentry: who the issue is assigned to, as a bucket: `"me"`, `"unassigned"`
    /// (a fresh unassigned error/fatal issue, last 24 h), `"unassigned_older"`
    /// (`assignedTo` is null but not in that fresh list: older and/or below error
    /// level) or `"other"` (assigned to another user or a team).
    /// Other sources leave it unset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assignee: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due: Option<NaiveDate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub metrics: BTreeMap<String, i64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub linked: Vec<String>,
    /// Title + body text for local search (≤ 64 KiB).
    #[serde(default)]
    pub search_text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sent: Vec<SentMarker>,
}

/// A labelled link in a detail view.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Link {
    pub label: String,
    pub url: String,
}

/// Detail for one work item (or a Fred mail / event).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkDetail {
    pub item_id: String,
    pub title: String,
    /// Ordered label/value rows.
    #[serde(default)]
    pub fields: Vec<(String, String)>,
    #[serde(default)]
    pub markdown: String,
    #[serde(default)]
    pub files: Vec<String>,
    #[serde(default)]
    pub links: Vec<Link>,
}

/// One of Teri's daily picks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pick {
    pub item_id: String,
    pub source: WorkSource,
    pub title: String,
    pub reason: String,
    #[serde(default)]
    pub done_since: bool,
}

/// Teri's published picks (`~/.nostromo/teri/picks.json`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PicksSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub generating: bool,
    #[serde(default)]
    pub unavailable_sources: Vec<WorkSource>,
    #[serde(default)]
    pub items: Vec<Pick>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Defaults the Mac shows in the "send to agent" sheet.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SendPreview {
    pub item_id: String,
    pub agent: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    pub label: String,
    /// The user's directive, pre-filled for the sheet to edit.
    #[serde(default)]
    pub instruction: String,
    /// What the agent will also receive, fenced as untrusted data: the item's
    /// own text, rebuilt by the daemon at send time. The sheet shows it
    /// READ-ONLY; it is never sent back, so editing cannot change it.
    pub context: String,
    /// Live markers for this item (duplicate warning).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub existing: Vec<SentMarker>,
}

/// Result of a send (or a Fred seed).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SendOutcome {
    /// `"created"` | `"existing"` | `"mother_job"` | `"seeded"`.
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
}

/// Outcome of a targeted request: a value, or a coded refusal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", content = "value", rename_all = "snake_case")]
pub enum WorkResult<T> {
    Ok(T),
    Err(WorkError),
}

/// Machine-readable error (`code`) plus a human-readable `message`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkError {
    pub code: String,
    pub message: String,
}

impl WorkError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn not_available() -> Self {
        Self::new("not_available", "not available yet")
    }

    pub fn requires_secure_connection() -> Self {
        Self::new(
            "requires_secure_connection",
            "this request requires a secure connection to your Mac",
        )
    }
}

impl<T> WorkResult<T> {
    pub fn err(code: impl Into<String>, message: impl Into<String>) -> Self {
        WorkResult::Err(WorkError::new(code, message))
    }
}

impl<T> From<Result<T, WorkError>> for WorkResult<T> {
    fn from(r: Result<T, WorkError>) -> Self {
        match r {
            Ok(v) => WorkResult::Ok(v),
            Err(e) => WorkResult::Err(e),
        }
    }
}
