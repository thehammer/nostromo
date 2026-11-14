//! The wire types of the authored-PR list (`ServerMsg::AuthoredPrs`).
//!
//! Every string that came from GitHub is sanitised with `one_line` and bounded
//! when a row is built ([`crate::data::authored_prs::build_snapshot`]); the
//! types here only carry the result. Kit decodes leniently, so every optional
//! field is skipped when absent. The in-memory head branch and SHA are not
//! fields of anything in this file, on purpose: they never reach the wire.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub const MAX_PRS: usize = 100;
pub const MAX_TITLE: usize = 300;
pub const MAX_BASE_REF: usize = 100;
pub const MAX_NAME: usize = 120;
pub const MAX_CHECK_NAME: usize = 100;
pub const MAX_FAILING_NAMES: usize = 20;
pub const MAX_LOGINS: usize = 10;
pub const MAX_CANDIDATES: usize = 8;
pub const MAX_HIDDEN_ORGS: usize = 10;
pub const MAX_ORG_NAME: usize = 60;
pub const MAX_NEW_COMMENTS: u32 = 999;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TokenState {
    Connected,
    Missing,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RelayState {
    Live,
    CatchingUp,
    Offline,
    NotConfigured,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelayInfo {
    pub state: RelayState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<DateTime<Utc>>,
    pub org: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PollState {
    Ok,
    Checking,
    RateLimited,
    Paused,
    Error,
    Idle,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollInfo {
    pub state: PollState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked_at: Option<DateTime<Utc>>,
    pub interval_secs: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resumes_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefreshBlocked {
    Running,
    RateLimited,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Group {
    NeedsYou,
    Ready,
    Waiting,
    Draft,
}

impl Group {
    /// Display order: Needs you, Ready, Waiting, Drafts.
    pub fn rank(self) -> u8 {
        match self {
            Group::NeedsYou => 0,
            Group::Ready => 1,
            Group::Waiting => 2,
            Group::Draft => 3,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Lifecycle {
    Open,
    Merged,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChecksState {
    Passing,
    Failing,
    Pending,
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Checks {
    pub state: ChecksState,
    pub passed: u32,
    pub failed: u32,
    pub pending: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failing_names: Vec<String>,
}

impl Checks {
    pub fn none() -> Self {
        Checks {
            state: ChecksState::None,
            passed: 0,
            failed: 0,
            pending: 0,
            failing_names: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewState {
    Approved,
    ChangesRequested,
    ReviewRequested,
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Review {
    pub state: ReviewState,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub logins: Vec<String>,
}

impl Review {
    pub fn none() -> Self {
        Review {
            state: ReviewState::None,
            logins: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OwnerKind {
    MotherJob,
    /// Reserved for slice 3 (a link the user made); never produced yet.
    Linked,
    OnBranch,
    Ambiguous,
    Closed,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Via {
    MotherJob,
    Linked,
    OnBranch,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Candidate {
    pub tag: String,
    pub name: String,
    pub via: Via,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Owner {
    pub kind: OwnerKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<Via>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub candidates: Vec<Candidate>,
}

impl Owner {
    pub fn unknown() -> Self {
        Owner {
            kind: OwnerKind::Unknown,
            tag: None,
            name: None,
            job_id: None,
            via: None,
            candidates: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoredPr {
    /// `owner/name`.
    pub repo: String,
    pub number: u64,
    /// Rebuilt from the repo and number, never GitHub's own string.
    pub url: String,
    pub title: String,
    pub draft: bool,
    pub updated_at: DateTime<Utc>,
    pub group: Group,
    pub lifecycle: Lifecycle,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub details_unavailable: bool,
    pub checks: Checks,
    pub review: Review,
    pub new_comments: u32,
    pub unresolved_threads: u32,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub threads_truncated: bool,
    pub owner: Owner,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct UsageCounts {
    pub charged: u64,
    pub not_modified: u64,
    pub search: u64,
    pub graphql_points: u64,
    pub relay_charged: u64,
    pub visible_charged: u64,
    pub hidden_charged: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageView {
    pub window_secs: u64,
    #[serde(flatten)]
    pub window: UsageCounts,
    pub since_start: UsageCounts,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoredPrsSnapshot {
    pub generated_at: DateTime<Utc>,
    pub token: TokenState,
    pub relay: RelayInfo,
    pub poll: PollInfo,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_blocked: Option<RefreshBlocked>,
    #[serde(default)]
    pub hidden_orgs: Vec<String>,
    pub total_open: u32,
    pub shown: u32,
    pub prs: Vec<AuthoredPr>,
    pub usage: UsageView,
}

/// A GitHub login as the API allows it (with an optional `[bot]` suffix).
pub fn valid_login(s: &str) -> bool {
    let core = s.strip_suffix("[bot]").unwrap_or(s);
    !core.is_empty()
        && core.len() <= 39
        && core.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// An owner or repo name as GitHub allows it.
pub fn safe_segment(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 100
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        && s != "."
        && s != ".."
}

/// `owner/name`, each part passing [`safe_segment`].
pub fn valid_repo(s: &str) -> bool {
    match s.split_once('/') {
        Some((o, n)) => safe_segment(o) && safe_segment(n),
        None => false,
    }
}
