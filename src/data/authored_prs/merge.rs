//! The Merge verb: squash-merge one of the user's own PRs, now, through GitHub,
//! with the daemon's token, when and only when every rule below holds.
//!
//! The Mac sends it after a human gesture; the daemon cannot see that, so it
//! enforces the rules itself and never trusts a cached row:
//!
//! 1. The PR is in the daemon's list. It is read from GitHub **right now** and
//!    must be open, not a draft, mergeable, approved by a human reviewer with
//!    its checks passing (or none), and GitHub's own `mergeStateStatus` must be
//!    `CLEAN` or `HAS_HOOKS`.
//! 2. The live head's first eight hex digits equal what the app was showing.
//! 3. Perri approved the **full** live head. A verdict for another head never
//!    counts.
//! 4. The merge request carries `sha` (the live head), so GitHub itself refuses
//!    when the head moved after the checks above, and never an admin or bypass
//!    parameter, so branch protection always applies.
//! 5. Where the base branch has a **merge queue** GitHub refuses a direct merge,
//!    so the same live read says which way the PR goes in (`merge_via`), and
//!    after every rule above the PR is *enqueued* instead
//!    (`enqueuePullRequest`, pinned to the live head with `expectedHeadOid`,
//!    never `jump`, never an admin or bypass input) and the answer is `queued`.
//!    The way the app worded its confirmation (`expected_via`; absent means a
//!    direct merge) must be the way GitHub says now, or nothing is sent
//!    (`via_changed`). If the live read cannot say whether a queue exists the
//!    verb refuses (`queue_unknown`): it never guesses. The queue is the BASE
//!    branch's (`repository.mergeQueue(branch: <base>)`), cross-checked against
//!    the PR's own `mergeQueue` field: no queue on the base is a direct merge,
//!    a queue needs both reads to say so (else `queue_unknown`). The live base
//!    branch must also be the one the row showed (else `via_changed`). A PR
//!    already in the queue answers `already_queued` and nothing is sent.
//!
//! Answers are codes only. Nothing GitHub says (a message, a title) is
//! forwarded or logged. One request id gets one answer, and a second request for
//! a PR whose merge is still in flight is refused `busy`. The one log line, on
//! success, names the repo, the number and the short head: the audit trail of
//! an irreversible action (no token, title or body). A refused attempt gets one
//! audit line too, with its code and who asked (`operator-app:<client_id>`).

use std::collections::{HashSet, VecDeque};
use std::sync::Mutex;

use super::actions::AuthoredPrActions;
use super::classify::{classify, is_human, RawPr};
use super::github::{ApiError, Failure, MergeError, Target, SECONDARY_WAIT};
use super::links::key_string;
use super::snapshot::{
    valid_repo, AuthoredPr, ChecksState, Lifecycle, MergeVia, PollState, ReviewState,
};
use super::verdicts::{is_full_sha, plain_text, short_sha, Verdict};
use super::wire::AuthoredPrResult;
use serde::{Deserialize, Serialize};

/// How many answers are remembered, for a repeated request id.
const REMEMBERED_MERGES: usize = 64;

/// The longest the verbs' own live reads stay quiet after GitHub says to wait
/// (a hostile or mistaken `Retry-After` of a day must not lock them out).
pub(super) const MAX_READ_WAIT_MINUTES: i64 = 15;

/// Every answer code the verb gives.
pub const CODES: [&str; 22] = [
    "ok",
    "queued",
    "already_queued",
    "queue_refused",
    "queue_unknown",
    "via_changed",
    "not_found",
    "not_open",
    "draft",
    "not_approved",
    "checks_not_green",
    "not_mergeable",
    "blocked",
    "behind",
    "head_changed",
    "perri_not_approved",
    "perri_stale",
    "token_cannot_merge",
    "rate_limited",
    "unreachable",
    "busy",
    "not_permitted",
];

/// A successful answer. `{}` is "merged now" (`ok`); `{"code":"queued"}` is "in
/// the merge queue" (`queued`). Never anything GitHub said.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct MergeDone {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}

/// What a successful call did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Merged,
    Queued,
}

/// Merges in flight and the answers already given.
#[derive(Default)]
pub struct MergeBook {
    state: Mutex<BookState>,
}

#[derive(Default)]
struct BookState {
    in_flight: HashSet<String>,
    /// `(request id, PR, answer)`: an id answers only for the PR it first named.
    answers: VecDeque<(String, String, AuthoredPrResult<MergeDone>)>,
}

/// Releases the PR's in-flight mark when dropped, even if the task is.
struct InFlight<'a> {
    book: &'a MergeBook,
    pr: String,
}

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.book
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .in_flight
            .remove(&self.pr);
    }
}

impl MergeBook {
    fn begin<'a>(&'a self, request_id: &str, pr: &str) -> BeginOutcome<'a> {
        let mut g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((_, _, r)) = g
            .answers
            .iter()
            .find(|(id, key, _)| id == request_id && key == pr)
        {
            return BeginOutcome::Again(r.clone());
        }
        if !g.in_flight.insert(pr.to_owned()) {
            return BeginOutcome::Busy;
        }
        BeginOutcome::Go(InFlight {
            book: self,
            pr: pr.to_owned(),
        })
    }

    fn remember(&self, request_id: &str, pr: &str, result: &AuthoredPrResult<MergeDone>) {
        let mut g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        g.answers
            .push_back((request_id.to_owned(), pr.to_owned(), result.clone()));
        while g.answers.len() > REMEMBERED_MERGES {
            g.answers.pop_front();
        }
    }
}

enum BeginOutcome<'a> {
    Again(AuthoredPrResult<MergeDone>),
    Busy,
    Go(InFlight<'a>),
}

/// The audit line for a merge attempt that did not merge: the repo, the number,
/// the head the app showed (short), who asked and the code. What the client sent
/// is shown only when it is the shape it must be (a client cannot put text in a
/// log line); never a token, title or anything GitHub said.
fn log_refusal(repo: &str, number: u64, head_short: &str, by: &str, code: &str, via: &str) {
    let head = Some(head_short)
        .filter(|h| h.len() == 8 && h.bytes().all(|b| b.is_ascii_hexdigit()))
        .unwrap_or("invalid");
    let repo = if valid_repo(repo) { repo } else { "invalid" };
    tracing::info!(
        repo = %repo,
        number,
        head = %head,
        by = %plain_text(by, 80),
        code,
        via,
        "authored-pr merge refused"
    );
}

fn refuse<T>(code: &'static str) -> Result<T, &'static str> {
    Err(code)
}

fn via_word(via: MergeVia) -> &'static str {
    match via {
        MergeVia::Direct => "direct",
        MergeVia::Queue => "queue",
    }
}

impl AuthoredPrActions {
    /// Merge `repo#number` (or add it to its merge queue). `expected_head_short`
    /// is the head the app showed; `expected_via` is the way it said the PR goes
    /// in (`None`: a direct merge, what an app that does not know queues says);
    /// `by` is who asked (an audit label, never content).
    pub async fn merge(
        &self,
        request_id: &str,
        repo: &str,
        number: u64,
        expected_head_short: &str,
        expected_via: Option<MergeVia>,
        by: &str,
    ) -> AuthoredPrResult<MergeDone> {
        let pr = key_string(repo, number);
        let _in_flight = match self.merges.begin(request_id, &pr) {
            BeginOutcome::Again(first) => return first,
            // Not remembered: it is not the first answer to anything.
            BeginOutcome::Busy => {
                log_refusal(repo, number, expected_head_short, by, "busy", "unknown");
                return AuthoredPrResult::err("busy");
            }
            BeginOutcome::Go(guard) => guard,
        };
        let mut via = "unknown";
        let result = match self
            .merge_once(
                repo,
                number,
                expected_head_short,
                expected_via,
                by,
                &mut via,
            )
            .await
        {
            Ok(Outcome::Merged) => AuthoredPrResult::Ok(MergeDone::default()),
            Ok(Outcome::Queued) => AuthoredPrResult::Ok(MergeDone {
                code: Some("queued".to_owned()),
            }),
            Err(code) => {
                log_refusal(repo, number, expected_head_short, by, code, via);
                AuthoredPrResult::err(code)
            }
        };
        self.merges.remember(request_id, &pr, &result);
        result
    }

    async fn merge_once(
        &self,
        repo: &str,
        number: u64,
        expected_head_short: &str,
        expected_via: Option<MergeVia>,
        by: &str,
        via_label: &mut &'static str,
    ) -> Result<Outcome, &'static str> {
        if !valid_repo(repo) || number == 0 {
            return refuse("not_found");
        }
        // The PR must be one in the list: the user's own.
        let row = self.row_any(repo, number).ok_or("not_found")?;
        if self.rate_limited_now() {
            return refuse("rate_limited");
        }
        let api = self
            .api
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
            .ok_or("token_cannot_merge")?;

        // Read the PR from GitHub now. Nothing below uses the cached row.
        let target = Target {
            repo: row.repo.clone(),
            number,
        };
        let live = match api.detail_for_merge(&target).await {
            Ok(Some(raw)) => raw,
            Ok(None) => return refuse("not_found"),
            Err(f) => {
                if matches!(f.error, ApiError::RateLimited { .. }) {
                    self.remember_rate_limit(&f);
                }
                return refuse(match f.error {
                    ApiError::RateLimited { .. } => "rate_limited",
                    ApiError::Unauthorized | ApiError::Forbidden => "token_cannot_merge",
                    _ => "unreachable",
                });
            }
        };
        // Already waiting in the queue: nothing to send, and nothing to gate.
        if live.is_in_merge_queue && classify(&live, None).lifecycle == Lifecycle::Open {
            *via_label = "queue";
            return refuse("already_queued");
        }
        check_live_state(&live)?;

        // The head the app showed is the head being merged.
        let head = live.head_ref_oid.as_str();
        if !is_full_sha(head) {
            return refuse("not_mergeable");
        }
        if short_sha(head).as_deref() != Some(expected_head_short) {
            return refuse("head_changed");
        }
        self.check_perri(&row.repo, number, head)?;

        // Every rule holds. How GitHub takes the PR in decides the action, and it
        // must be the way the app told the person.
        let via = live.merge_via().ok_or("queue_unknown")?;
        // The queue decision was made for the live base branch: it must be the
        // one the row showed, or the person confirmed something else.
        if classify(&live, None).base_ref != row.base_ref {
            *via_label = via_word(via);
            return refuse("via_changed");
        }
        *via_label = via_word(via);
        if expected_via.unwrap_or(MergeVia::Direct) != via {
            return refuse("via_changed");
        }
        if via == MergeVia::Queue {
            return self.enqueue_once(&api, &row, &live, number, head, by).await;
        }

        match api.merge(&row.repo, number, head).await {
            Ok(()) => {}
            Err(e) => {
                return refuse(match e {
                    MergeError::NotAllowed => "blocked",
                    MergeError::HeadMoved => "head_changed",
                    MergeError::Forbidden | MergeError::Unauthorized => "token_cannot_merge",
                    MergeError::NotFound => "not_found",
                    MergeError::Unmergeable => "not_mergeable",
                    MergeError::RateLimited => "rate_limited",
                    MergeError::Transport => "unreachable",
                })
            }
        }
        tracing::info!(
            repo = %row.repo,
            number,
            head = %&head[..8],
            by = %plain_text(by, 80),
            via = "direct",
            "authored-pr merged"
        );
        // The row turns merged on the next read: ask for it now.
        self.changed(&row);
        Ok(Outcome::Merged)
    }

    /// Add the PR to its merge queue, pinned to `head`.
    async fn enqueue_once(
        &self,
        api: &super::github::Api,
        row: &AuthoredPr,
        live: &RawPr,
        number: u64,
        head: &str,
        by: &str,
    ) -> Result<Outcome, &'static str> {
        match api.enqueue(&live.id, head).await {
            Ok(()) => {}
            Err(e) => {
                return refuse(match e {
                    MergeError::HeadMoved => "head_changed",
                    MergeError::Forbidden | MergeError::Unauthorized => "token_cannot_merge",
                    MergeError::NotFound => "not_found",
                    MergeError::RateLimited => "rate_limited",
                    MergeError::Transport => "unreachable",
                    // GitHub declined to enqueue (not ready, conflicts, ...).
                    MergeError::NotAllowed | MergeError::Unmergeable => "queue_refused",
                });
            }
        }
        tracing::info!(
            repo = %row.repo,
            number,
            head = %&head[..8],
            by = %plain_text(by, 80),
            via = "queue",
            "authored-pr queued"
        );
        // The row shows its queue entry on the next read: ask for it now.
        self.changed(row);
        Ok(Outcome::Queued)
    }

    /// Perri approved exactly `head`. A verdict for any other head is `perri_stale`.
    fn check_perri(&self, repo: &str, number: u64, head: &str) -> Result<(), &'static str> {
        match self.verdicts.for_head(repo, number, head) {
            Some(r) if r.verdict == Verdict::Approved => Ok(()),
            Some(_) => refuse("perri_not_approved"),
            None if self.verdicts.newest(repo, number).is_some() => refuse("perri_stale"),
            None => refuse("perri_not_approved"),
        }
    }

    /// The engine is hard-paused on a rate limit that has not ended: the merge
    /// waits with it. (`resumes_at` is only ever set while paused; the slower
    /// `rate_limited` poll state is a slow-down, not a stop.)
    pub(super) fn rate_limited_now(&self) -> bool {
        if self.read_wait_pending() {
            return true;
        }
        let snap = self.snapshot.borrow();
        let Some(snap) = snap.as_ref() else {
            return false;
        };
        snap.poll.state == PollState::Paused
            && snap.poll.resumes_at.is_some_and(|t| t > self.clock.now())
    }

    /// GitHub answered one of the verbs' own live reads with a rate limit:
    /// remember how long it said to wait (capped), so the next reads refuse
    /// locally instead of spending the allowance while the poller, idle, has
    /// not noticed. A wait that has not ended is never shortened.
    pub(super) fn remember_rate_limit(&self, f: &Failure) {
        let now = self.clock.now();
        let until = match f.error {
            ApiError::RateLimited { wait: Some(w) } => {
                now + chrono::Duration::from_std(w).unwrap_or_default()
            }
            _ => f.meta.rate.map(|(_, o)| o.reset).unwrap_or_else(|| {
                now + chrono::Duration::from_std(SECONDARY_WAIT).unwrap_or_default()
            }),
        }
        .min(now + chrono::Duration::minutes(MAX_READ_WAIT_MINUTES));
        let mut held = self.read_wait.lock().unwrap_or_else(|e| e.into_inner());
        if held.is_none_or(|t| t < until) {
            *held = Some(until);
        }
    }

    fn read_wait_pending(&self) -> bool {
        let held = self.read_wait.lock().unwrap_or_else(|e| e.into_inner());
        held.is_some_and(|t| t > self.clock.now())
    }

    /// The PR `repo#number` in the latest snapshot, whatever its lifecycle.
    pub(super) fn row_any(&self, repo: &str, number: u64) -> Option<AuthoredPr> {
        let snap = self.snapshot.borrow();
        snap.as_ref()?
            .prs
            .iter()
            .find(|p| p.number == number && p.repo.eq_ignore_ascii_case(repo))
            .cloned()
    }
}

/// The rules GitHub's own answer must meet, in the order their codes are given.
fn check_live_state(live: &RawPr) -> Result<(), &'static str> {
    let c = classify(live, None);
    if c.lifecycle != Lifecycle::Open {
        return refuse("not_open");
    }
    if live.is_draft {
        return refuse("draft");
    }
    if live.mergeable != "MERGEABLE" {
        return refuse("not_mergeable");
    }
    if c.review.state != ReviewState::Approved || !human_approved(live) {
        return refuse("not_approved");
    }
    if !matches!(c.checks.state, ChecksState::Passing | ChecksState::None) {
        return refuse("checks_not_green");
    }
    // GitHub's own verdict has the last word.
    match live.merge_state_status.as_str() {
        "CLEAN" | "HAS_HOOKS" => Ok(()),
        "BEHIND" => refuse("behind"),
        "BLOCKED" => refuse("blocked"),
        "UNSTABLE" => refuse("checks_not_green"),
        "DRAFT" => refuse("draft"),
        _ => refuse("not_mergeable"),
    }
}

/// At least one human (a user, not a bot) has approved.
fn human_approved(live: &RawPr) -> bool {
    live.latest_opinionated_reviews.nodes.iter().any(|r| {
        r.state.eq_ignore_ascii_case("APPROVED") && r.author.as_ref().is_some_and(is_human)
    })
}
