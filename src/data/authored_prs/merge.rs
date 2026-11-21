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
use super::github::{ApiError, MergeError, Target};
use super::links::key_string;
use super::snapshot::{valid_repo, AuthoredPr, ChecksState, Lifecycle, PollState, ReviewState};
use super::verdicts::{is_full_sha, plain_text, short_sha, Verdict};
use super::wire::{AuthoredPrResult, Done};

/// How many answers are remembered, for a repeated request id.
const REMEMBERED_MERGES: usize = 64;

/// Every answer code the verb gives.
pub const CODES: [&str; 17] = [
    "ok",
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

/// Merges in flight and the answers already given.
#[derive(Default)]
pub struct MergeBook {
    state: Mutex<BookState>,
}

#[derive(Default)]
struct BookState {
    in_flight: HashSet<String>,
    /// `(request id, PR, answer)`: an id answers only for the PR it first named.
    answers: VecDeque<(String, String, AuthoredPrResult<Done>)>,
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

    fn remember(&self, request_id: &str, pr: &str, result: &AuthoredPrResult<Done>) {
        let mut g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        g.answers
            .push_back((request_id.to_owned(), pr.to_owned(), result.clone()));
        while g.answers.len() > REMEMBERED_MERGES {
            g.answers.pop_front();
        }
    }
}

enum BeginOutcome<'a> {
    Again(AuthoredPrResult<Done>),
    Busy,
    Go(InFlight<'a>),
}

/// The audit line for a merge attempt that did not merge: the repo, the number,
/// the head the app showed (short), who asked and the code. What the client sent
/// is shown only when it is the shape it must be (a client cannot put text in a
/// log line); never a token, title or anything GitHub said.
fn log_refusal(repo: &str, number: u64, head_short: &str, by: &str, code: &str) {
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
        "authored-pr merge refused"
    );
}

fn refuse(code: &'static str) -> Result<(), &'static str> {
    Err(code)
}

impl AuthoredPrActions {
    /// Merge `repo#number`. `expected_head_short` is the head the app showed;
    /// `by` is who asked (an audit label, never content).
    pub async fn merge(
        &self,
        request_id: &str,
        repo: &str,
        number: u64,
        expected_head_short: &str,
        by: &str,
    ) -> AuthoredPrResult<Done> {
        let pr = key_string(repo, number);
        let _in_flight = match self.merges.begin(request_id, &pr) {
            BeginOutcome::Again(first) => return first,
            // Not remembered: it is not the first answer to anything.
            BeginOutcome::Busy => {
                log_refusal(repo, number, expected_head_short, by, "busy");
                return AuthoredPrResult::err("busy");
            }
            BeginOutcome::Go(guard) => guard,
        };
        let result = match self.merge_once(repo, number, expected_head_short, by).await {
            Ok(()) => AuthoredPrResult::Ok(Done {}),
            Err(code) => {
                log_refusal(repo, number, expected_head_short, by, code);
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
        by: &str,
    ) -> Result<(), &'static str> {
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
                return refuse(match f.error {
                    ApiError::RateLimited { .. } => "rate_limited",
                    ApiError::Unauthorized => "token_cannot_merge",
                    _ => "unreachable",
                })
            }
        };
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
            "authored-pr merged"
        );
        // The row turns merged on the next read: ask for it now.
        self.changed(&row);
        Ok(())
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
        let snap = self.snapshot.borrow();
        let Some(snap) = snap.as_ref() else {
            return false;
        };
        snap.poll.state == PollState::Paused
            && snap.poll.resumes_at.is_some_and(|t| t > self.clock.now())
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
