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

#[cfg(test)]
mod tests {
    //! What a PR's raw GraphQL answer means. Pure: JSON in, a verdict out. The
    //! fixtures are the answer's own JSON (what GitHub sends), so a rename of
    //! an internal type changes nothing here.

    use super::*;
    use serde_json::{json, Value};

    const ME: &str = "me-author";

    fn at(h: u32, m: u32) -> DateTime<Utc> {
        use chrono::TimeZone;
        Utc.with_ymd_and_hms(2026, 11, 14, h, m, 0).unwrap()
    }

    fn ts(h: u32, m: u32) -> String {
        at(h, m).to_rfc3339()
    }

    /// An open, ordinary PR with no checks, reviews or comments.
    fn pr_json() -> Value {
        json!({
            "number": 7,
            "title": "A change",
            "isDraft": false,
            "state": "OPEN",
            "merged": false,
            "updatedAt": ts(12, 0),
            "author": {"__typename": "User", "login": ME},
            "baseRefName": "main",
            "headRefName": "feat/x",
            "headRefOid": "abc123",
            "repository": {"nameWithOwner": "Carefeed/app", "defaultBranchRef": {"name": "main"}},
            "commits": {"nodes": [{"commit": {"committedDate": ts(10, 0), "statusCheckRollup": null}}]},
            "latestOpinionatedReviews": {"nodes": []},
            "reviewRequests": {"nodes": []},
            "reviewThreads": {"totalCount": 0, "nodes": []},
            "comments": {"nodes": []},
            "reviews": {"nodes": []},
        })
    }

    fn raw(v: Value) -> RawPr {
        serde_json::from_value(v).expect("a PR answer decodes")
    }

    fn with_contexts(contexts: Vec<Value>) -> Value {
        let mut v = pr_json();
        v["commits"]["nodes"][0]["commit"]["statusCheckRollup"] = json!({
            "contexts": {"totalCount": contexts.len(), "nodes": contexts}
        });
        v
    }

    fn check_run(name: &str, status: &str, conclusion: Option<&str>) -> Value {
        json!({"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion})
    }

    fn status_ctx(context: &str, state: &str) -> Value {
        json!({"__typename": "StatusContext", "context": context, "state": state})
    }

    fn checks_of(contexts: Vec<Value>) -> Checks {
        classify(&raw(with_contexts(contexts)), None).checks
    }

    // ── checks ────────────────────────────────────────────────────────────

    #[test]
    fn a_single_check_is_classified_by_its_status_and_conclusion() {
        use ChecksState as S;
        // (status, conclusion, state, passed, failed, pending)
        type Row<'a> = (&'a str, Option<&'a str>, ChecksState, u32, u32, u32);
        let table: Vec<Row> = vec![
            ("COMPLETED", Some("SUCCESS"), S::Passing, 1, 0, 0),
            ("completed", Some("success"), S::Passing, 1, 0, 0),
            ("COMPLETED", Some("FAILURE"), S::Failing, 0, 1, 0),
            ("COMPLETED", Some("TIMED_OUT"), S::Failing, 0, 1, 0),
            ("COMPLETED", Some("ACTION_REQUIRED"), S::Failing, 0, 1, 0),
            ("COMPLETED", Some("STALE"), S::Failing, 0, 1, 0),
            ("IN_PROGRESS", None, S::Pending, 0, 0, 1),
            ("QUEUED", None, S::Pending, 0, 0, 1),
            ("WAITING", None, S::Pending, 0, 0, 1),
            ("PENDING", None, S::Pending, 0, 0, 1),
            ("REQUESTED", None, S::Pending, 0, 0, 1),
            // Skipped, cancelled and neutral say nothing either way.
            ("COMPLETED", Some("SKIPPED"), S::None, 0, 0, 0),
            ("COMPLETED", Some("CANCELLED"), S::None, 0, 0, 0),
            ("COMPLETED", Some("NEUTRAL"), S::None, 0, 0, 0),
        ];
        for (status, conclusion, state, passed, failed, pending) in table {
            let c = checks_of(vec![check_run("build", status, conclusion)]);
            assert_eq!(
                (c.state, c.passed, c.failed, c.pending),
                (state, passed, failed, pending),
                "{status} / {conclusion:?}"
            );
        }
    }

    #[test]
    fn a_commit_status_context_is_classified_by_its_state() {
        use ChecksState as S;
        for (state, want) in [
            ("SUCCESS", S::Passing),
            ("FAILURE", S::Failing),
            ("ERROR", S::Failing),
            ("PENDING", S::Pending),
            ("EXPECTED", S::Pending),
            ("SOMETHING_NEW", S::None),
        ] {
            let c = checks_of(vec![status_ctx("ci/legacy", state)]);
            assert_eq!(c.state, want, "{state}");
        }
    }

    #[test]
    fn a_failure_outranks_pending_which_outranks_success_and_no_checks_is_none() {
        let failing = checks_of(vec![
            check_run("a", "COMPLETED", Some("SUCCESS")),
            check_run("b", "IN_PROGRESS", None),
            check_run("c", "COMPLETED", Some("FAILURE")),
        ]);
        assert_eq!(failing.state, ChecksState::Failing);
        assert_eq!((failing.passed, failing.failed, failing.pending), (1, 1, 1));

        let pending = checks_of(vec![
            check_run("a", "COMPLETED", Some("SUCCESS")),
            check_run("b", "QUEUED", None),
        ]);
        assert_eq!(pending.state, ChecksState::Pending);

        let passing = checks_of(vec![
            check_run("a", "COMPLETED", Some("SUCCESS")),
            check_run("b", "COMPLETED", Some("SKIPPED")),
            status_ctx("ci/legacy", "SUCCESS"),
        ]);
        assert_eq!(passing.state, ChecksState::Passing);
        assert_eq!(passing.passed, 2);

        assert_eq!(checks_of(vec![]).state, ChecksState::None);
        // No rollup at all (a commit nothing has run on).
        assert_eq!(classify(&raw(pr_json()), None).checks, Checks::none());
    }

    #[test]
    fn failing_check_names_are_listed_one_line_and_bounded() {
        let mut contexts = vec![
            check_run("unit tests", "COMPLETED", Some("FAILURE")),
            status_ctx("ci/legacy", "FAILURE"),
            check_run(&format!("long-{}", "n".repeat(500)), "COMPLETED", Some("FAILURE")),
            check_run("multi\nline\u{1b}[31mname", "COMPLETED", Some("FAILURE")),
        ];
        for i in 0..40 {
            contexts.push(check_run(&format!("extra-{i}"), "COMPLETED", Some("FAILURE")));
        }
        let c = checks_of(contexts);
        assert_eq!(c.failed, 44, "every failure is counted");
        assert!(c.failing_names.len() <= MAX_FAILING_NAMES, "{}", c.failing_names.len());
        assert_eq!(c.failing_names[0], "unit tests");
        assert_eq!(c.failing_names[1], "ci/legacy", "a status context is named by its context");
        for n in &c.failing_names {
            assert!(n.chars().count() <= MAX_CHECK_NAME, "{n}");
            assert!(!n.chars().any(|ch| ch.is_control()), "{n:?}");
        }
    }

    #[test]
    fn passing_checks_name_nothing() {
        let c = checks_of(vec![check_run("secret-name", "COMPLETED", Some("SUCCESS"))]);
        assert!(c.failing_names.is_empty());
    }

    // ── review ────────────────────────────────────────────────────────────

    fn review_node(state: &str, login: &str) -> Value {
        json!({"state": state, "author": {"__typename": "User", "login": login}})
    }

    fn requested_user(login: &str) -> Value {
        json!({"requestedReviewer": {"__typename": "User", "login": login}})
    }

    fn requested_team(org: &str, slug: &str) -> Value {
        json!({"requestedReviewer": {"__typename": "Team", "slug": slug, "organization": {"login": org}}})
    }

    fn review_of(reviews: Vec<Value>, requests: Vec<Value>) -> Review {
        let mut v = pr_json();
        v["latestOpinionatedReviews"]["nodes"] = json!(reviews);
        v["reviewRequests"]["nodes"] = json!(requests);
        classify(&raw(v), None).review
    }

    #[test]
    fn review_state_is_exactly_one_of_changes_requested_approved_review_requested_none() {
        let both = review_of(
            vec![review_node("APPROVED", "alice"), review_node("CHANGES_REQUESTED", "bob")],
            vec![requested_user("carol")],
        );
        assert_eq!(both.state, ReviewState::ChangesRequested, "changes outranks approval");
        assert_eq!(both.logins, vec!["bob".to_string()]);

        let approved = review_of(
            vec![review_node("APPROVED", "alice")],
            vec![requested_user("carol")],
        );
        assert_eq!(approved.state, ReviewState::Approved, "approval outranks a pending request");
        assert_eq!(approved.logins, vec!["alice".to_string()]);

        let requested = review_of(vec![], vec![requested_user("carol")]);
        assert_eq!(requested.state, ReviewState::ReviewRequested);
        assert_eq!(requested.logins, vec!["carol".to_string()]);

        let none = review_of(vec![review_node("COMMENTED", "dave")], vec![]);
        assert_eq!(none, Review::none());
    }

    #[test]
    fn a_requested_team_is_named_org_slash_slug_and_an_unsafe_one_is_dropped() {
        let r = review_of(
            vec![],
            vec![
                requested_team("Carefeed", "backend"),
                requested_team("Carefeed", "bad slug"),
                requested_team("Care feed", "ok"),
            ],
        );
        assert_eq!(r.state, ReviewState::ReviewRequested);
        assert_eq!(r.logins, vec!["Carefeed/backend".to_string()]);

        let only_bad = review_of(vec![], vec![requested_team("Carefeed", "bad slug")]);
        assert_eq!(only_bad, Review::none(), "nothing safe to show is no request");
    }

    #[test]
    fn reviewer_logins_are_valid_unique_and_at_most_ten() {
        let mut nodes = vec![
            review_node("APPROVED", "alice"),
            review_node("APPROVED", "alice"),
            review_node("APPROVED", "not a login"),
            review_node("APPROVED", &"x".repeat(60)),
            review_node("APPROVED", "copilot-reviewer[bot]"),
        ];
        for i in 0..30 {
            nodes.push(review_node("APPROVED", &format!("user-{i}")));
        }
        let r = review_of(nodes, vec![]);
        assert_eq!(r.state, ReviewState::Approved);
        assert!(r.logins.len() <= MAX_LOGINS, "{}", r.logins.len());
        assert_eq!(r.logins.iter().filter(|l| *l == "alice").count(), 1);
        assert!(r.logins.contains(&"copilot-reviewer[bot]".to_string()));
        assert!(r.logins.iter().all(|l| valid_login(l)), "{:?}", r.logins);
    }

    // ── new comments ──────────────────────────────────────────────────────

    fn comment(login: &str, typename: &str, when: DateTime<Utc>) -> Value {
        json!({"createdAt": when.to_rfc3339(), "author": {"__typename": typename, "login": login}})
    }

    fn review_event(login: &str, typename: &str, when: DateTime<Utc>, comments: u32) -> Value {
        json!({
            "submittedAt": when.to_rfc3339(),
            "author": {"__typename": typename, "login": login},
            "comments": {"totalCount": comments}
        })
    }

    fn new_comments(comments: Vec<Value>, reviews: Vec<Value>) -> u32 {
        let mut v = pr_json(); // the last push is 10:00
        v["comments"]["nodes"] = json!(comments);
        v["reviews"]["nodes"] = json!(reviews);
        classify(&raw(v), None).new_comments
    }

    #[test]
    fn a_comment_by_someone_else_after_the_last_push_is_new() {
        assert_eq!(new_comments(vec![comment("alice", "User", at(11, 0))], vec![]), 1);
        assert_eq!(
            new_comments(
                vec![comment("alice", "User", at(11, 0)), comment("bob", "User", at(11, 5))],
                vec![review_event("carol", "User", at(11, 10), 3)],
            ),
            5,
            "issue comments plus a review's comment count"
        );
    }

    #[test]
    fn the_authors_own_comments_do_not_count() {
        assert_eq!(new_comments(vec![comment(ME, "User", at(11, 0))], vec![]), 0);
        assert_eq!(
            new_comments(vec![], vec![review_event(ME, "User", at(11, 0), 4)]),
            0
        );
        // Logins compare without regard to case.
        assert_eq!(
            new_comments(vec![comment(&ME.to_uppercase(), "User", at(11, 0))], vec![]),
            0
        );
    }

    #[test]
    fn bots_do_not_count_whether_by_typename_by_suffix_or_by_name() {
        assert_eq!(new_comments(vec![comment("some-app", "Bot", at(11, 0))], vec![]), 0);
        assert_eq!(
            new_comments(vec![comment("renovate[bot]", "User", at(11, 0))], vec![]),
            0,
            "a [bot] suffix is a bot whatever the typename says"
        );
        assert_eq!(new_comments(vec![comment("dependabot", "User", at(11, 0))], vec![]), 0);
        assert_eq!(new_comments(vec![comment("carefeed-ci", "User", at(11, 0))], vec![]), 0);
        assert_eq!(
            new_comments(vec![], vec![review_event("ci[bot]", "Bot", at(11, 0), 9)]),
            0
        );
    }

    #[test]
    fn a_comment_older_than_the_last_push_or_at_the_same_moment_is_not_new() {
        assert_eq!(new_comments(vec![comment("alice", "User", at(9, 0))], vec![]), 0);
        assert_eq!(
            new_comments(vec![comment("alice", "User", at(10, 0))], vec![]),
            0,
            "the push moment itself is not after the push"
        );
        assert_eq!(
            new_comments(vec![], vec![review_event("alice", "User", at(9, 59), 6)]),
            0
        );
        assert_eq!(new_comments(vec![comment("alice", "User", at(10, 1))], vec![]), 1);
    }

    #[test]
    fn a_comment_with_no_timestamp_is_not_counted_when_there_is_a_push_to_compare_with() {
        let c = json!({"author": {"__typename": "User", "login": "alice"}});
        assert_eq!(new_comments(vec![c], vec![]), 0);
    }

    #[test]
    fn without_a_commit_date_every_human_comment_counts() {
        let mut v = pr_json();
        v["commits"] = json!({"nodes": []});
        v["comments"]["nodes"] = json!([comment("alice", "User", at(1, 0))]);
        assert_eq!(classify(&raw(v), None).new_comments, 1);
    }

    #[test]
    fn the_told_time_raises_the_cutoff_above_the_push() {
        let mut v = pr_json();
        v["comments"]["nodes"] = json!([
            comment("alice", "User", at(11, 0)),
            comment("alice", "User", at(13, 0)),
        ]);
        let pr = raw(v);
        assert_eq!(count_new_comments(&pr, None), 2);
        assert_eq!(count_new_comments(&pr, Some(at(12, 0))), 1);
        assert_eq!(count_new_comments(&pr, Some(at(8, 0))), 2, "an older told time changes nothing");
    }

    #[test]
    fn the_new_comment_count_is_capped_at_999() {
        let many: Vec<Value> = (0..1200).map(|_| comment("alice", "User", at(11, 0))).collect();
        assert_eq!(new_comments(many, vec![]), 999);
        assert_eq!(
            new_comments(vec![], vec![review_event("alice", "User", at(11, 0), 4_000_000_000)]),
            999,
            "a huge review comment count cannot overflow or exceed the cap"
        );
    }

    // ── threads ───────────────────────────────────────────────────────────

    #[test]
    fn unresolved_threads_are_counted_and_truncation_is_flagged_past_one_hundred() {
        let mut v = pr_json();
        let nodes: Vec<Value> = (0..100).map(|i| json!({"isResolved": i % 4 == 0})).collect();
        v["reviewThreads"] = json!({"totalCount": 100, "nodes": nodes});
        let c = classify(&raw(v.clone()), None);
        assert_eq!(c.unresolved_threads, 75);
        assert!(!c.threads_truncated, "100 of 100 is everything");

        v["reviewThreads"]["totalCount"] = json!(101);
        let c = classify(&raw(v), None);
        assert_eq!(c.unresolved_threads, 75, "only the first 100 are seen");
        assert!(c.threads_truncated, "101 threads: one was not read");

        let none = classify(&raw(pr_json()), None);
        assert_eq!((none.unresolved_threads, none.threads_truncated), (0, false));
    }

    // ── base branch ───────────────────────────────────────────────────────

    #[test]
    fn the_base_branch_is_shown_only_when_it_is_neither_main_nor_the_repos_default() {
        assert_eq!(base_ref_to_show("main", Some("main")), None);
        assert_eq!(base_ref_to_show("main", Some("develop")), None, "main is never shown");
        assert_eq!(base_ref_to_show("develop", Some("develop")), None, "the default is not shown");
        assert_eq!(
            base_ref_to_show("release/2026-11", Some("main")),
            Some("release/2026-11".to_string())
        );
        assert_eq!(base_ref_to_show("feature/base", None), Some("feature/base".to_string()));
        assert_eq!(base_ref_to_show("", Some("main")), None);

        let long = base_ref_to_show(&format!("b-{}", "x".repeat(400)), Some("main")).unwrap();
        assert!(long.chars().count() <= MAX_BASE_REF, "{}", long.chars().count());

        let mut v = pr_json();
        v["baseRefName"] = json!("stack/base");
        assert_eq!(classify(&raw(v), None).base_ref.as_deref(), Some("stack/base"));
        assert_eq!(classify(&raw(pr_json()), None).base_ref, None);
    }

    // ── lifecycle ─────────────────────────────────────────────────────────

    #[test]
    fn lifecycle_follows_merged_then_state() {
        let mut v = pr_json();
        assert_eq!(classify(&raw(v.clone()), None).lifecycle, Lifecycle::Open);
        v["state"] = json!("CLOSED");
        assert_eq!(classify(&raw(v.clone()), None).lifecycle, Lifecycle::Closed);
        v["state"] = json!("MERGED");
        assert_eq!(classify(&raw(v.clone()), None).lifecycle, Lifecycle::Merged);
        v["state"] = json!("CLOSED");
        v["merged"] = json!(true);
        assert_eq!(classify(&raw(v), None).lifecycle, Lifecycle::Merged, "merged wins over closed");
    }

    // ── groups ────────────────────────────────────────────────────────────

    fn checks_with(state: ChecksState, failed: u32) -> Checks {
        Checks {
            state,
            passed: 0,
            failed,
            pending: 0,
            failing_names: vec![],
        }
    }

    fn review_with(state: ReviewState) -> Review {
        Review {
            state,
            logins: vec![],
        }
    }

    #[test]
    fn a_draft_is_in_drafts_whatever_else_is_true() {
        let g = group_of(
            true,
            &checks_with(ChecksState::Failing, 3),
            &review_with(ReviewState::ChangesRequested),
            5,
            2,
        );
        assert_eq!(g, Group::Draft);
    }

    #[test]
    fn each_thing_that_needs_the_author_puts_the_pr_in_needs_you() {
        let ok = checks_with(ChecksState::Passing, 0);
        let none = review_with(ReviewState::None);
        assert_eq!(
            group_of(false, &checks_with(ChecksState::Failing, 1), &none, 0, 0),
            Group::NeedsYou,
            "a failing check"
        );
        assert_eq!(
            group_of(false, &ok, &review_with(ReviewState::ChangesRequested), 0, 0),
            Group::NeedsYou,
            "changes requested"
        );
        assert_eq!(group_of(false, &ok, &none, 1, 0), Group::NeedsYou, "a new comment");
        assert_eq!(group_of(false, &ok, &none, 0, 1), Group::NeedsYou, "an unresolved thread");
        assert_eq!(
            group_of(false, &ok, &review_with(ReviewState::Approved), 0, 1),
            Group::NeedsYou,
            "approval does not outrank an open thread"
        );
        assert_eq!(
            group_of(false, &checks_with(ChecksState::Failing, 1), &review_with(ReviewState::Approved), 0, 0),
            Group::NeedsYou,
            "approved but red"
        );
    }

    #[test]
    fn approved_with_passing_or_no_checks_is_ready_and_everything_else_waits() {
        let approved = review_with(ReviewState::Approved);
        assert_eq!(
            group_of(false, &checks_with(ChecksState::Passing, 0), &approved, 0, 0),
            Group::Ready
        );
        assert_eq!(
            group_of(false, &checks_with(ChecksState::None, 0), &approved, 0, 0),
            Group::Ready
        );
        assert_eq!(
            group_of(false, &checks_with(ChecksState::Pending, 0), &approved, 0, 0),
            Group::Waiting,
            "approved while checks still run"
        );
        for r in [ReviewState::ReviewRequested, ReviewState::None] {
            for c in [ChecksState::Passing, ChecksState::Pending, ChecksState::None] {
                assert_eq!(
                    group_of(false, &checks_with(c, 0), &review_with(r), 0, 0),
                    Group::Waiting,
                    "{r:?} / {c:?}"
                );
            }
        }
    }

    // ── a whole answer ────────────────────────────────────────────────────

    #[test]
    fn a_whole_answer_is_classified_end_to_end() {
        let mut v = with_contexts(vec![check_run("lint", "COMPLETED", Some("SUCCESS"))]);
        v["latestOpinionatedReviews"]["nodes"] = json!([review_node("APPROVED", "alice")]);
        v["comments"]["nodes"] = json!([comment("bob", "User", at(11, 0))]);
        v["baseRefName"] = json!("release");
        let c = classify(&raw(v), None);
        assert_eq!(c.checks.state, ChecksState::Passing);
        assert_eq!(c.review.state, ReviewState::Approved);
        assert_eq!(c.new_comments, 1);
        assert_eq!(c.base_ref.as_deref(), Some("release"));
        assert_eq!(c.lifecycle, Lifecycle::Open);
    }
}
