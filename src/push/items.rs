//! The item model (W13): what is waiting on the operator, derived from the
//! snapshots the primary sees (its own and every satellite's).
//!
//! **No free-text field is read here.** A Mother job contributes its id's
//! 8-hex suffix, `state`, `paused_reason`, `activity`, `paused_at`, its open
//! decision's presence, its attention reasons and `since`, and the owner/repo of
//! its `pr_url`. A review contributes `bucket`, `repo`, `number` and
//! `changed_lines`. Nothing a worker, an agent, a person or GitHub wrote
//! (question, title, plan path, branch, notes, author, labels) is a parameter of
//! any function in this module, so none can reach a notification.
//!
//! The Mother rules mirror the Kit `MotherNeedsYouProducer` (MC4); the shared
//! golden table is `tests/fixtures/push-items/mother_jobs.json`.

use chrono::{DateTime, Utc};

use crate::data::perri_queue::PrQueueItem;
use crate::mother::MotherJob;
use crate::push::owner::parse_github_url;
use crate::push::wire::{AgentClass, Presence, PushKind};

/// What identifies an item over its lifetime. A Mother job that leaves
/// `awaiting` and re-enters is a new item only because it was absent from a
/// snapshot in between; an attention reason that lapses and returns carries a
/// new `since`, so it is a new key.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ItemKey {
    Mother {
        host: String,
        job_id: String,
    },
    /// `progress_stalled`, `burn_ahead` or `gates_incomplete`: counted, never pushed.
    Attention {
        host: String,
        job_id: String,
        reason: String,
        since: String,
    },
    Decision {
        host: String,
        request_id: String,
    },
    Review {
        host: String,
        repo: String,
        number: u64,
    },
}

impl ItemKey {
    /// The per-kind switch that governs the item.
    pub fn kind(&self) -> PushKind {
        match self {
            ItemKey::Mother { .. } | ItemKey::Attention { .. } => PushKind::Mother,
            ItemKey::Decision { .. } => PushKind::Decision,
            ItemKey::Review { .. } => PushKind::Review,
        }
    }
}

/// Why a Mother job is waiting, from the fixed set the phrase table covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MotherReason {
    /// `paused_reason: user`
    Asked,
    /// `adherence_blocked`
    BlockedAfterReview,
    /// `operator_hold`
    HeldAfterFailure,
    /// `cost_cap`
    SpendCap,
    /// `activity: pipeline_blocked`
    PipelineBlocked,
    /// Anything else.
    NeedsYou,
}

/// The per-kind facts of an item: closed vocabulary only.
#[derive(Debug, Clone, PartialEq)]
pub enum Detail {
    Mother {
        /// The 8-hex suffix of the job id, when it validates.
        job_ref: Option<String>,
        reason: MotherReason,
        /// From the job's `pr_url`; unknown (`None`) without one, and always
        /// `None` for a job queued from a work item.
        repo: Option<String>,
        owner: Option<String>,
    },
    /// Counted in the badge and the next Summary; never pushed on its own.
    Attention,
    Decision {
        agent: AgentClass,
        choices: usize,
        deadline: Option<DateTime<Utc>>,
        presence: Option<Presence>,
        repo: Option<String>,
        owner: Option<String>,
    },
    Review {
        number: u64,
        changed_lines: Option<u64>,
        repo: String,
        owner: Option<String>,
    },
}

/// One item waiting on the operator.
#[derive(Debug, Clone, PartialEq)]
pub struct Waiting {
    pub key: ItemKey,
    /// The opaque random identifier that is the only thing sent to the relay
    /// about the item (its `apns-collapse-id`). Assigned by the engine.
    pub item_ref: String,
    /// The host label as the operator knows it (`kobe`, `tokyo`).
    pub host: String,
    /// When the item started to wait, if the source says (Mother's `paused_at`,
    /// an attention `since`); else the engine's first-seen time.
    pub start: Option<DateTime<Utc>>,
    pub detail: Detail,
    /// Already waiting when its host's first snapshot arrived (a daemon
    /// restart, or a satellite that just connected): counted in the badge and
    /// the summaries, never pushed. Set by the engine.
    pub preexisting: bool,
}

impl Waiting {
    pub fn kind(&self) -> PushKind {
        self.key.kind()
    }

    /// Count-only items never push on their own.
    pub fn is_count_only(&self) -> bool {
        matches!(self.detail, Detail::Attention)
    }
}

/// Attention reasons that count toward the badge and the next Summary.
const COUNTED_ATTENTION: &[&str] = &["progress_stalled", "burn_ahead", "gates_incomplete"];

/// The 8-hex suffix of a Mother job id (`YYYYMMDDTHHMMSSZ-xxxxxxxx`), if it is one.
pub fn job_ref(id: &str) -> Option<String> {
    let suffix = id.rsplit('-').next()?;
    (suffix.len() == 8
        && suffix
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')))
    .then(|| suffix.to_string())
}

fn reason_of(job: &MotherJob) -> MotherReason {
    match job.paused_reason.as_deref() {
        Some("user") => MotherReason::Asked,
        Some("adherence_blocked") => MotherReason::BlockedAfterReview,
        Some("operator_hold") => MotherReason::HeldAfterFailure,
        Some("cost_cap") => MotherReason::SpendCap,
        _ if job.activity.as_deref() == Some("pipeline_blocked") => MotherReason::PipelineBlocked,
        _ => MotherReason::NeedsYou,
    }
}

/// The items a Mother snapshot holds for `host`: one per awaiting or held job
/// (not a quota pause, which resumes on its own), plus one per unacknowledged
/// attention reason of the three counted kinds. Works on a full job and on a
/// metadata-shaped one alike.
pub fn mother_items(host: &str, jobs: &[MotherJob]) -> Vec<Waiting> {
    let mut items = Vec::new();
    for job in jobs {
        let quota = job
            .paused_reason
            .as_deref()
            .is_some_and(|r| r.starts_with("quota_"));
        if (job.is_awaiting() || job.is_held_for_operator()) && !quota {
            // A job queued from a work item is work data: no repository, ever.
            let remote = if job.is_work_send() {
                None
            } else {
                job.pr_url.as_deref().and_then(parse_github_url)
            };
            items.push(Waiting {
                key: ItemKey::Mother {
                    host: host.to_string(),
                    job_id: job.id.clone(),
                },
                item_ref: String::new(),
                host: host.to_string(),
                start: job.paused_at,
                detail: Detail::Mother {
                    job_ref: job_ref(&job.id),
                    reason: reason_of(job),
                    repo: remote.as_ref().map(|r| r.repo.clone()),
                    owner: remote.map(|r| r.owner),
                },
                preexisting: false,
            });
        }
        for entry in job.unacked_attention() {
            if !COUNTED_ATTENTION.contains(&entry.reason.as_str()) {
                continue;
            }
            let since = entry.since.clone().unwrap_or_default();
            items.push(Waiting {
                start: DateTime::parse_from_rfc3339(&since)
                    .ok()
                    .map(|t| t.with_timezone(&Utc)),
                key: ItemKey::Attention {
                    host: host.to_string(),
                    job_id: job.id.clone(),
                    reason: entry.reason.clone(),
                    since,
                },
                item_ref: String::new(),
                host: host.to_string(),
                detail: Detail::Attention,
                preexisting: false,
            });
        }
    }
    items
}

/// The items a Perri queue holds for `host`: the PRs in the `requested` bucket.
pub fn review_items(host: &str, queue: &[PrQueueItem]) -> Vec<Waiting> {
    queue
        .iter()
        .filter(|pr| pr.bucket == "requested")
        .map(|pr| {
            let owner = pr
                .repo
                .split_once('/')
                .map(|(owner, _)| owner.to_string())
                .filter(|o| !o.is_empty());
            let repo = pr.repo.rsplit('/').next().unwrap_or(&pr.repo).to_string();
            Waiting {
                key: ItemKey::Review {
                    host: host.to_string(),
                    repo: pr.repo.clone(),
                    number: pr.number,
                },
                item_ref: String::new(),
                host: host.to_string(),
                start: None,
                detail: Detail::Review {
                    number: pr.number,
                    changed_lines: pr.changed_lines,
                    repo,
                    owner,
                },
                preexisting: false,
            }
        })
        .collect()
}

/// The facts of an open decision, as its `DecisionRequest` carries them.
pub struct DecisionFacts {
    pub request_id: String,
    pub choices: usize,
    pub deadline: Option<DateTime<Utc>>,
    pub agent: Option<AgentClass>,
    pub presence: Option<Presence>,
    pub repo: Option<String>,
    pub owner: Option<String>,
}

/// An open decision as an item. It starts when it was raised, which the engine
/// knows (`raised`), not the frame.
pub fn decision_item(host: &str, facts: &DecisionFacts, raised: DateTime<Utc>) -> Waiting {
    Waiting {
        key: ItemKey::Decision {
            host: host.to_string(),
            request_id: facts.request_id.clone(),
        },
        item_ref: String::new(),
        host: host.to_string(),
        start: Some(raised),
        detail: Detail::Decision {
            agent: facts.agent.unwrap_or(AgentClass::Other),
            choices: facts.choices,
            deadline: facts.deadline,
            presence: facts.presence,
            repo: facts.repo.clone(),
            owner: facts.owner.clone(),
        },
        preexisting: false,
    }
}
