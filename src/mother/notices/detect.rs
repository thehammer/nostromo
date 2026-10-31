//! What changed about a job between two looks at the feed.
//!
//! The vocabulary is the PRD's (D3): `queued`, `ready`, `running`,
//! `retry_started` and `pr_closed` are **quiet** (they never start a turn and
//! ride along in the next delivery); `awaiting` (needs you), `succeeded`,
//! `failed`, `cancelled` and `pr_merged` are **waking**; `pr_opened` wakes for
//! window purposes (with a terminal state in the same window it is one wake).

use serde::{Deserialize, Serialize};

use crate::mother::MotherJob;

/// One change to a job, as a notice names it (`state` / `since` tokens).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobEvent {
    Queued,
    Ready,
    Running,
    RetryStarted,
    PrOpened,
    Awaiting,
    Succeeded,
    Failed,
    Cancelled,
    PrMerged,
    PrClosed,
}

impl JobEvent {
    /// The token in a notice (`state="…"`, `since="…"`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Ready => "ready",
            Self::Running => "running",
            Self::RetryStarted => "retry_started",
            Self::PrOpened => "pr_opened",
            Self::Awaiting => "awaiting",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::PrMerged => "pr_merged",
            Self::PrClosed => "pr_closed",
        }
    }

    /// Does this change open (or join as waking) a batch window?
    pub fn is_waking(self) -> bool {
        matches!(
            self,
            Self::PrOpened
                | Self::Awaiting
                | Self::Succeeded
                | Self::Failed
                | Self::Cancelled
                | Self::PrMerged
        )
    }

    /// The event for a Mother job `state`; `None` for a state notices do not
    /// name.
    pub fn from_state(state: &str) -> Option<Self> {
        Some(match state {
            "queued" => Self::Queued,
            "ready" => Self::Ready,
            "running" => Self::Running,
            "awaiting" => Self::Awaiting,
            "succeeded" => Self::Succeeded,
            "failed" => Self::Failed,
            "cancelled" => Self::Cancelled,
            _ => return None,
        })
    }
}

/// What the engine remembers of a job from the previous look.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Seen<'a> {
    pub state: &'a str,
    pub has_pr: bool,
}

/// The changes from `prev` to `job`, oldest first. `prev = None` is a job seen
/// for the first time (after bootstrap): its state is a change, and so is a
/// PR it already has.
///
/// A PR that appears is reported before a state change seen at the same time,
/// so `pr_opened` then `succeeded` reads `state="succeeded" since="pr_opened"`.
/// A `failed` job that moves back to `queued`, `ready` or `running` is
/// `retry_started`.
pub fn changes(prev: Option<Seen<'_>>, job: &MotherJob) -> Vec<JobEvent> {
    let mut out = Vec::new();
    let has_pr = job.pr_url.is_some();
    let (prev_state, prev_pr) = match &prev {
        Some(seen) => (Some(seen.state), seen.has_pr),
        None => (None, false),
    };
    if has_pr && !prev_pr {
        out.push(JobEvent::PrOpened);
    }
    if prev_state != Some(job.state.as_str()) {
        let retry = prev_state == Some("failed")
            && matches!(job.state.as_str(), "queued" | "ready" | "running");
        if retry {
            out.push(JobEvent::RetryStarted);
        } else if let Some(event) = JobEvent::from_state(&job.state) {
            out.push(event);
        }
    }
    // A job first seen with a PR and a non-final state: the PR is newer news
    // than "running", so it goes last.
    if prev.is_none() && out.len() == 2 && !out[1].is_waking() {
        out.swap(0, 1);
    }
    out
}
