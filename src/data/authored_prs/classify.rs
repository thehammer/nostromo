//! What a pull request's raw GraphQL answer means: checks, review, new
//! comments, unresolved threads, base branch and group. Pure.
//!
//! The raw types hold timestamps, counts, states and logins only. The query
//! never asks for a body or a check's output, so there is nothing else to hold.

use chrono::{DateTime, Utc};
use serde::Deserialize;

use super::snapshot::{
    safe_segment, valid_login, Checks, ChecksState, Group, Lifecycle, Review, ReviewState,
    MAX_BASE_REF, MAX_CHECK_NAME, MAX_FAILING_NAMES, MAX_LOGINS, MAX_NEW_COMMENTS,
};
use crate::data::perri_queue::CiState;
use crate::data::perri_queue_native::is_bot;
use crate::data::work::untrusted::one_line;

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Nodes<T> {
    #[serde(default = "Vec::new")]
    pub nodes: Vec<T>,
    #[serde(default, rename = "totalCount")]
    pub total_count: u32,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Actor {
    #[serde(default, rename = "__typename")]
    pub typename: String,
    #[serde(default)]
    pub login: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawContext {
    #[serde(default, rename = "__typename")]
    pub typename: String,
    // CheckRun
    pub name: Option<String>,
    pub status: Option<String>,
    pub conclusion: Option<String>,
    // StatusContext
    pub context: Option<String>,
    pub state: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawRollup {
    #[serde(default)]
    pub contexts: Nodes<RawContext>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawCommit {
    #[serde(default, rename = "committedDate")]
    pub committed_date: Option<DateTime<Utc>>,
    #[serde(default, rename = "statusCheckRollup")]
    pub status_check_rollup: Option<RawRollup>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawCommitNode {
    #[serde(default)]
    pub commit: RawCommit,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawReview {
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub author: Option<Actor>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawRequested {
    #[serde(default, rename = "requestedReviewer")]
    pub requested_reviewer: Option<RawReviewer>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawReviewer {
    #[serde(default, rename = "__typename")]
    pub typename: String,
    pub login: Option<String>,
    pub slug: Option<String>,
    pub organization: Option<RawOrg>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawOrg {
    #[serde(default)]
    pub login: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawThread {
    #[serde(default, rename = "isResolved")]
    pub is_resolved: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawComment {
    #[serde(default, rename = "createdAt")]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub author: Option<Actor>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawReviewEvent {
    #[serde(default, rename = "submittedAt")]
    pub submitted_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub author: Option<Actor>,
    #[serde(default)]
    pub comments: Nodes<serde::de::IgnoredAny>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawDefaultBranch {
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawRepository {
    #[serde(default, rename = "nameWithOwner")]
    pub name_with_owner: String,
    #[serde(default, rename = "defaultBranchRef")]
    pub default_branch_ref: Option<RawDefaultBranch>,
}

/// One pull request as the `AuthoredPrDetail` query returns it.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawPr {
    #[serde(default)]
    pub number: u64,
    #[serde(default)]
    pub title: String,
    #[serde(default, rename = "isDraft")]
    pub is_draft: bool,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub merged: bool,
    #[serde(default, rename = "updatedAt")]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub author: Option<Actor>,
    #[serde(default, rename = "baseRefName")]
    pub base_ref_name: String,
    #[serde(default, rename = "headRefName")]
    pub head_ref_name: String,
    #[serde(default, rename = "headRefOid")]
    pub head_ref_oid: String,
    #[serde(default)]
    pub repository: RawRepository,
    #[serde(default)]
    pub commits: Nodes<RawCommitNode>,
    #[serde(default, rename = "latestOpinionatedReviews")]
    pub latest_opinionated_reviews: Nodes<RawReview>,
    #[serde(default, rename = "reviewRequests")]
    pub review_requests: Nodes<RawRequested>,
    #[serde(default, rename = "reviewThreads")]
    pub review_threads: Nodes<RawThread>,
    #[serde(default)]
    pub comments: Nodes<RawComment>,
    #[serde(default)]
    pub reviews: Nodes<RawReviewEvent>,
}

/// What the classifier concludes about one PR. Everything the wire row needs
/// except the title, owner and timestamps.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Classified {
    pub checks: Checks,
    pub review: Review,
    pub new_comments: u32,
    pub unresolved_threads: u32,
    pub threads_truncated: bool,
    pub base_ref: Option<String>,
    pub lifecycle: Lifecycle,
}

/// A human: a `User`, not a known bot and not a `[bot]` account.
pub fn is_human(actor: &Actor) -> bool {
    actor.typename == "User" && !is_bot(&actor.login) && !actor.login.ends_with("[bot]")
}

/// Map one check context onto Perri's four-way state, so both features call a
/// check the same thing.
pub fn context_state(c: &RawContext) -> CiState {
    if c.typename == "StatusContext" {
        return match c.state.as_deref().map(str::to_ascii_lowercase).as_deref() {
            Some("success") => CiState::Success,
            Some("failure" | "error") => CiState::Failure,
            Some("pending" | "expected") => CiState::Pending,
            _ => CiState::Unknown,
        };
    }
    let status = c.status.as_deref().map(str::to_ascii_lowercase);
    let conclusion = c.conclusion.as_deref().map(str::to_ascii_lowercase);
    CiState::from_check(status.as_deref(), conclusion.as_deref())
}

pub fn classify_checks(contexts: &[RawContext]) -> Checks {
    let mut passed = 0u32;
    let mut failed = 0u32;
    let mut pending = 0u32;
    let mut failing_names = Vec::new();
    let mut states = Vec::new();
    for c in contexts {
        let s = context_state(c);
        states.push(s);
        match s {
            CiState::Success => passed += 1,
            CiState::Failure => {
                failed += 1;
                if failing_names.len() < MAX_FAILING_NAMES {
                    let name = c.name.as_deref().or(c.context.as_deref()).unwrap_or("");
                    let name = one_line(name, MAX_CHECK_NAME);
                    if !name.is_empty() {
                        failing_names.push(name);
                    }
                }
            }
            CiState::Pending => pending += 1,
            CiState::Unknown => {}
        }
    }
    let state = match CiState::rollup(states) {
        CiState::Failure => ChecksState::Failing,
        CiState::Pending => ChecksState::Pending,
        CiState::Success => ChecksState::Passing,
        CiState::Unknown => ChecksState::None,
    };
    Checks {
        state,
        passed,
        failed,
        pending,
        failing_names,
    }
}

fn push_login(out: &mut Vec<String>, login: &str) {
    if valid_login(login) && out.len() < MAX_LOGINS && !out.iter().any(|l| l == login) {
        out.push(login.to_owned());
    }
}

/// Exactly one of changes requested, approved, review requested, none.
pub fn classify_review(pr: &RawPr) -> Review {
    let by_state = |wanted: &str| {
        let mut logins = Vec::new();
        for r in &pr.latest_opinionated_reviews.nodes {
            if r.state.eq_ignore_ascii_case(wanted) {
                if let Some(a) = &r.author {
                    push_login(&mut logins, &a.login);
                }
            }
        }
        logins
    };
    let changes = by_state("CHANGES_REQUESTED");
    if !changes.is_empty() {
        return Review {
            state: ReviewState::ChangesRequested,
            logins: changes,
        };
    }
    let approved = by_state("APPROVED");
    if !approved.is_empty() {
        return Review {
            state: ReviewState::Approved,
            logins: approved,
        };
    }
    let mut requested = Vec::new();
    for req in &pr.review_requests.nodes {
        let Some(r) = &req.requested_reviewer else {
            continue;
        };
        match r.typename.as_str() {
            "Team" => {
                if let (Some(slug), Some(org)) = (&r.slug, &r.organization) {
                    if safe_segment(slug) && safe_segment(&org.login) {
                        let team = format!("{}/{}", org.login, slug);
                        if requested.len() < MAX_LOGINS && !requested.contains(&team) {
                            requested.push(team);
                        }
                    }
                }
            }
            _ => {
                if let Some(login) = &r.login {
                    push_login(&mut requested, login);
                }
            }
        }
    }
    if requested.is_empty() {
        Review::none()
    } else {
        Review {
            state: ReviewState::ReviewRequested,
            logins: requested,
        }
    }
}

/// Comments (issue comments plus review comments) by a human other than the
/// PR's author, posted after `cutoff`.
///
/// The cutoff is the last commit's committed date, an approximation of "the
/// last push" (a force-push of an old commit does not move it), later the max
/// with the time the user said they had dealt with the PR (slice 3's `told`).
pub fn count_new_comments(pr: &RawPr, told: Option<DateTime<Utc>>) -> u32 {
    let last_push = pr
        .commits
        .nodes
        .last()
        .and_then(|n| n.commit.committed_date);
    let cutoff = match (last_push, told) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, b) => a.or(b),
    };
    let author = pr.author.as_ref().map(|a| a.login.as_str()).unwrap_or("");
    let counts = |actor: &Option<Actor>, at: Option<DateTime<Utc>>| -> bool {
        let Some(a) = actor else { return false };
        if !is_human(a) || a.login.eq_ignore_ascii_case(author) {
            return false;
        }
        match (cutoff, at) {
            (Some(c), Some(t)) => t > c,
            (Some(_), None) => false,
            (None, _) => true,
        }
    };
    let mut n: u64 = 0;
    for c in &pr.comments.nodes {
        if counts(&c.author, c.created_at) {
            n += 1;
        }
    }
    for r in &pr.reviews.nodes {
        if counts(&r.author, r.submitted_at) {
            n += u64::from(r.comments.total_count);
        }
    }
    n.min(u64::from(MAX_NEW_COMMENTS)) as u32
}

/// Unresolved review threads among the first 100, and whether there were more.
pub fn count_unresolved(pr: &RawPr) -> (u32, bool) {
    let n = pr.review_threads.nodes.iter().filter(|t| !t.is_resolved).count() as u32;
    (n, pr.review_threads.total_count as usize > pr.review_threads.nodes.len())
}

/// The base branch, only when it is neither `main` nor the repo's default.
pub fn base_ref_to_show(base: &str, default_branch: Option<&str>) -> Option<String> {
    if base.is_empty() || base == "main" || Some(base) == default_branch {
        return None;
    }
    let s = one_line(base, MAX_BASE_REF);
    (!s.is_empty()).then_some(s)
}

pub fn lifecycle_of(pr: &RawPr) -> Lifecycle {
    if pr.merged || pr.state.eq_ignore_ascii_case("MERGED") {
        Lifecycle::Merged
    } else if pr.state.eq_ignore_ascii_case("CLOSED") {
        Lifecycle::Closed
    } else {
        Lifecycle::Open
    }
}

pub fn classify(pr: &RawPr, told: Option<DateTime<Utc>>) -> Classified {
    let contexts: Vec<RawContext> = pr
        .commits
        .nodes
        .last()
        .and_then(|n| n.commit.status_check_rollup.as_ref())
        .map(|r| r.contexts.nodes.clone())
        .unwrap_or_default();
    let (unresolved_threads, threads_truncated) = count_unresolved(pr);
    Classified {
        checks: classify_checks(&contexts),
        review: classify_review(pr),
        new_comments: count_new_comments(pr, told),
        unresolved_threads,
        threads_truncated,
        base_ref: base_ref_to_show(
            &pr.base_ref_name,
            pr.repository
                .default_branch_ref
                .as_ref()
                .map(|d| d.name.as_str()),
        ),
        lifecycle: lifecycle_of(pr),
    }
}

/// Draft whatever else; then Needs you (a failing check, changes requested, a
/// new comment, an unresolved thread); then Ready (approved, checks passing or
/// none); else Waiting.
pub fn group_of(
    draft: bool,
    checks: &Checks,
    review: &Review,
    new_comments: u32,
    unresolved_threads: u32,
) -> Group {
    if draft {
        Group::Draft
    } else if checks.failed > 0
        || review.state == ReviewState::ChangesRequested
        || new_comments > 0
        || unresolved_threads > 0
    {
        Group::NeedsYou
    } else if review.state == ReviewState::Approved
        && matches!(checks.state, ChecksState::Passing | ChecksState::None)
    {
        Group::Ready
    } else {
        Group::Waiting
    }
}
