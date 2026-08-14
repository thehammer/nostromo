//! Targeted per-PR queue updates, driven by the github-relay event payload.
//!
//! The queue has two paths that can decide a PR's bucket:
//!
//! * The **periodic full fetch** ([`super::perri_queue_native::PerriQueueNativeSource::fetch`])
//!   — three org-wide `/search/issues` calls plus per-candidate reads. It runs
//!   on the 60-second timer, the dirty file, the MCP push, the approvals file,
//!   and on relay (re)connect. It is the correctness backstop and the audit
//!   vantage point.
//! * The **targeted path** (this module) — one relay event drives an update of
//!   exactly one PR, usually with **zero** GitHub requests and at worst one
//!   GraphQL call plus one check-runs call. It **never** calls a search
//!   endpoint.
//!
//! The headline property: search traffic is a function of elapsed time, not of
//! relay event volume.
//!
//! # No event triggers a full refresh
//!
//! When the targeted path cannot settle a PR from scoped reads it does
//! **nothing** ([`Outcome::Deferred`]) and lets the next 60-second poll settle
//! it — up to 60s stale for that one PR. There is deliberately no
//! immediate-full-refresh fallback keyed off a relay event: re-adding three
//! search calls per unsettleable event is exactly the cost this module exists
//! to remove. (Relay *connect* and *reconnect* still force a full refresh —
//! the relay buffers nothing for an absent subscriber, so a reconnect is a
//! reconciliation, not an event.)
//!
//! # `needs_review` without a search call
//!
//! Bucket 2 is `review:required`, a field GitHub computes for the *search
//! index* and returns from no REST PR read. GraphQL exposes the same fact
//! per-PR as `PullRequest.reviewDecision`, and GraphQL draws on a separate
//! rate-limit pool (5000 points/hour; this query costs 1) from the
//! 30-searches-per-minute bucket that is the actual cliff. That is the whole
//! trick: see [`probe_pr`].
//!
//! # Drift
//!
//! A second path that can bucket a PR is a second chance to bucket it wrongly.
//! Two things bound that: the targeted path reuses the full fetch's own
//! [`classify`]/[`render_items`]/[`has_new_activity`]/`ci_state_for_sha`
//! rather than approximating them, and every poll audits the PRs a targeted
//! update touched since the last poll ([`diff_snapshots`]) and `warn!`s on
//! disagreement.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, SecondsFormat, Utc};
use serde::Deserialize;
use tracing::debug;

use crate::data::{
    github_client::GithubClient,
    perri_queue::{CiState, PrQueueItem},
    perri_queue_native::{
        api_base, base_headers, ci_state_for_sha, classify_bucket, fetch_check_runs_state, is_bot,
        Candidate, QueueCaches,
    },
    perri_suppress::{unix_now_secs, SuppressStore},
    relay_client::RelayEvent,
};

// ── Classification ────────────────────────────────────────────────────────────

/// What a relay event resolves to.
///
/// The variants are ordered by cost, cheapest first. Everything except
/// [`Action::Probe`] and [`Action::CiOnly`] is free.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// No state change, no GitHub call. The overwhelmingly common case for an
    /// org-wide subscription: news about someone else's PR.
    Ignore,
    /// Drop the PR from the ledger. Zero GitHub calls — every search the full
    /// fetch runs is `is:open`, so a merged or closed PR is never a member.
    Remove,
    /// Clear buckets 1 and 2 and record our `CHANGES_REQUESTED` review. Zero
    /// GitHub calls: the event carries everything needed.
    LeaveBuckets12,
    /// Read this one PR: 1 GraphQL request, plus 0-or-1 check-runs request.
    Probe,
    /// Re-read check-runs for one SHA: exactly 1 non-search request.
    CiOnly { head_sha: String },
}

/// What applying an event did to the ledger.
///
/// There is deliberately no `Action::Defer`: classification can always reach a
/// verdict, because "this event names nothing I can act on" *is* a verdict
/// ([`Action::Ignore`], free). Deferral is a **runtime** outcome — the one thing
/// that can fail is a scoped read — so it lives here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// The ledger changed — the caller must re-render and publish.
    Changed,
    /// Nothing changed; no publish needed.
    Unchanged,
    /// Could not settle the PR from scoped reads. The ledger and the snapshot
    /// are untouched and the next periodic poll owns it — up to 60s stale for
    /// this one PR. Never a full refresh.
    Deferred,
}

impl Outcome {
    pub fn is_changed(self) -> bool {
        matches!(self, Outcome::Changed)
    }
}

/// Decide what an event means for the queue, without touching the network.
///
/// Pure: the only inputs are the event, the authenticated login, and the
/// candidate ledger. Unknown event types and events missing the identity
/// fields they need classify to [`Action::Ignore`] — deleting
/// `relay_client::is_queue_relevant` moved that decision here so it lives in
/// exactly one place.
pub fn classify_event(ev: &RelayEvent, me: &str, caches: &QueueCaches) -> Action {
    let Some(repo) = ev.repo.as_deref() else {
        return Action::Ignore;
    };

    // `ci.completed` carries a SHA and no PR number, so it is keyed by SHA.
    if ev.event_type == "ci.completed" {
        let Some(sha) = ev.head_sha.as_deref().filter(|s| !s.is_empty()) else {
            return Action::Ignore;
        };
        let is_candidate_head = caches
            .candidates
            .values()
            .any(|c| c.repo == repo && c.head_sha == sha);
        return if is_candidate_head {
            Action::CiOnly {
                head_sha: sha.to_owned(),
            }
        } else {
            // The bulk of org-wide CI noise lands here.
            Action::Ignore
        };
    }

    let Some(number) = ev.number else {
        return Action::Ignore;
    };
    let in_ledger = caches
        .candidates
        .contains_key(&(repo.to_owned(), number));
    let reviewer_is_me = ev
        .reviewer
        .as_deref()
        .is_some_and(|r| logins_match(r, me));

    match ev.event_type.as_str() {
        // All three searches are `is:open`; a terminal PR is never a member.
        "pr.merged" | "pr.closed" => {
            if in_ledger {
                Action::Remove
            } else {
                Action::Ignore
            }
        }

        // Bucket 1 tracks review requests naming *me*. A request naming
        // somebody else satisfies neither `review-requested:@me` nor
        // `review:required`, so it changes no bucket. Removal is not blind
        // either: the PR may still qualify for bucket 2 or 3, which is what
        // the probe settles.
        "pr.review_requested" | "pr.review_request_removed" => {
            if reviewer_is_me {
                Action::Probe
            } else {
                Action::Ignore
            }
        }

        "pr.review_submitted" => {
            if reviewer_is_me {
                match ev.review_state.as_deref() {
                    // A comment changes no bucket.
                    Some("commented") => Action::Ignore,
                    // Leaves buckets 1 and 2 and does *not* enter bucket 3 yet
                    // — the 30s grace window means it returns only once the
                    // author responds.
                    Some("changes_requested") => Action::LeaveBuckets12,
                    // One approval may not satisfy the branch's requirement,
                    // so bucket-2 membership has to be re-read.
                    Some("approved") => Action::Probe,
                    // Unknown/absent review state — nothing defensible to do.
                    _ => Action::Ignore,
                }
            } else if in_ledger {
                // Someone else's review can end `review:required` and drop the
                // PR out of bucket 2. It can never *add* a PR to my queue.
                Action::Probe
            } else {
                Action::Ignore
            }
        }

        // A push moves the head SHA (CI must be re-read), can dismiss stale
        // approvals and restore `review:required`, can flip bucket 3's
        // `new_activity`, and can un-hide a candidate that only a red CI hid.
        "pr.synchronize" => Action::Probe,

        // A brand-new PR can enter `needs_review` immediately — and the direct
        // read is *fresher* than the search index, which may not list it yet.
        "pr.opened" | "pr.reopened" => Action::Probe,

        // Event types outside the subscribed vocabulary are ignored, not an
        // error. Widening what the relay *forwards* must not widen what the
        // queue *acts on*.
        _ => Action::Ignore,
    }
}

// ── Dedup / ordering state ────────────────────────────────────────────────────

/// What an event is "about", for ordering purposes.
///
/// `ci.completed` carries no PR number, so it orders by SHA; everything else
/// orders by PR.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum EventTarget {
    Pr(String, u64),
    Sha(String, String),
}

/// The most recent event applied to a PR, for the divergence log.
#[derive(Debug, Clone)]
pub struct LastEvent {
    pub event_type: String,
    pub event_id: String,
    pub at: DateTime<Utc>,
}

/// How many `event_id`s to remember. The relay delivers a few events a minute;
/// 512 covers hours of history for a handful of bytes each.
const SEEN_ID_CAPACITY: usize = 512;

/// Above this many ordering entries, drop everything older than an hour. Only
/// a backstop against a long-running daemon accumulating one entry per SHA
/// seen across the whole org.
const LAST_APPLIED_SOFT_CAP: usize = 1024;

/// Cross-event state the targeted path carries between wakes.
#[derive(Default)]
pub struct TargetedState {
    /// Bounded FIFO of applied `event_id`s, oldest evicted.
    seen_ids: VecDeque<String>,
    seen_set: HashSet<String>,
    /// Newest `delivered_at` applied per target.
    last_applied: HashMap<EventTarget, DateTime<Utc>>,
    /// PRs a targeted update touched since the last full poll — the audit set.
    pub touched_since_poll: HashSet<(String, u64)>,
    /// Most recent event applied per PR, quoted in the divergence `warn`.
    pub last_event: HashMap<(String, u64), LastEvent>,
    /// So "the relay is sending events without ids" is logged once, not once
    /// per event.
    missing_event_id_logged: bool,
}

impl TargetedState {
    /// Record that `key`'s verdict now comes from a targeted update.
    fn mark_touched(&mut self, key: &(String, u64), incoming: Incoming<'_>) {
        self.touched_since_poll.insert(key.clone());
        self.last_event.insert(
            key.clone(),
            LastEvent {
                event_type: incoming.ev.event_type.clone(),
                event_id: incoming.ev.event_id.clone().unwrap_or_default(),
                at: incoming.delivered_at,
            },
        );
    }

    /// Forget per-PR event history for PRs no longer in the ledger.
    pub fn prune(&mut self, live: &HashMap<(String, u64), Candidate>) {
        self.last_event.retain(|k, _| live.contains_key(k));
    }

    fn record_applied(&mut self, incoming: Incoming<'_>, target: Option<EventTarget>) {
        let at = incoming.delivered_at;
        if let Some(id) = incoming.ev.event_id.clone() {
            if self.seen_set.insert(id.clone()) {
                self.seen_ids.push_back(id);
                while self.seen_ids.len() > SEEN_ID_CAPACITY {
                    if let Some(evicted) = self.seen_ids.pop_front() {
                        self.seen_set.remove(&evicted);
                    }
                }
            }
        }
        if let Some(target) = target {
            self.last_applied.insert(target, at);
        }
        if self.last_applied.len() > LAST_APPLIED_SOFT_CAP {
            let cutoff = at - chrono::Duration::hours(1);
            self.last_applied.retain(|_, seen| *seen >= cutoff);
        }
    }
}

/// A relay event together with its resolved delivery timestamp.
///
/// The two travel as a pair through every apply helper: the timestamp gates
/// ordering *and* is what a zero-traffic action records as "when this happened",
/// so letting them drift apart would be a real bug.
#[derive(Clone, Copy)]
struct Incoming<'a> {
    ev: &'a RelayEvent,
    delivered_at: DateTime<Utc>,
}

/// What an event is about, or `None` when it names nothing orderable.
fn event_target(ev: &RelayEvent) -> Option<EventTarget> {
    let repo = ev.repo.clone()?;
    if ev.event_type == "ci.completed" {
        let sha = ev.head_sha.clone().filter(|s| !s.is_empty())?;
        Some(EventTarget::Sha(repo, sha))
    } else {
        Some(EventTarget::Pr(repo, ev.number?))
    }
}

// ── Apply ─────────────────────────────────────────────────────────────────────

/// Apply one relay event to the candidate ledger.
///
/// Dedup and ordering are checked **before** classification, so a duplicate
/// `ci.completed` costs zero requests rather than one.
///
/// Returns [`Outcome::Changed`] when the caller must re-render and publish.
pub async fn apply_relay_event(
    client: &GithubClient,
    me: &str,
    ev: &RelayEvent,
    caches: &mut QueueCaches,
    suppress: &Arc<Mutex<SuppressStore>>,
    state: &mut TargetedState,
) -> Outcome {
    let target = event_target(ev);

    // 1. Dedup by event_id.
    if let Some(id) = ev.event_id.as_deref() {
        if state.seen_set.contains(id) {
            debug!(
                event_type = %ev.event_type,
                event_id = %id,
                "perri targeted: duplicate event_id — dropped"
            );
            return Outcome::Unchanged;
        }
    } else if !state.missing_event_id_logged {
        state.missing_event_id_logged = true;
        debug!(
            event_type = %ev.event_type,
            "perri targeted: relay event carries no event_id — cannot dedup"
        );
    }

    // 2. Ordering. Ties are allowed through: two checks really can complete in
    //    the same millisecond, and dropping the second would lose news.
    let incoming = Incoming {
        ev,
        delivered_at: ev.delivered_at.unwrap_or_else(Utc::now),
    };
    let delivered_at = incoming.delivered_at;
    if let Some(target) = &target {
        if let Some(prev) = state.last_applied.get(target) {
            if delivered_at < *prev {
                debug!(
                    event_type = %ev.event_type,
                    delivered_at = %delivered_at,
                    last_applied = %prev,
                    "perri targeted: out-of-order event — dropped"
                );
                return Outcome::Unchanged;
            }
        }
    }

    // 3. Classify and act.
    let action = classify_event(ev, me, caches);
    let outcome = match action {
        Action::Ignore => Outcome::Unchanged,
        Action::Remove => {
            let key = pr_key(ev).expect("Remove implies repo+number");
            state.mark_touched(&key, incoming);
            if remove_candidate(caches, &key) {
                Outcome::Changed
            } else {
                Outcome::Unchanged
            }
        }
        Action::LeaveBuckets12 => {
            let key = pr_key(ev).expect("LeaveBuckets12 implies repo+number");
            apply_leave_buckets_12(caches, &key, state, incoming)
        }
        Action::CiOnly { head_sha } => {
            let repo = ev.repo.clone().expect("CiOnly implies repo");
            apply_ci_only(client, &repo, &head_sha, caches, state, incoming).await
        }
        Action::Probe => {
            let key = pr_key(ev).expect("Probe implies repo+number");
            apply_probe(client, me, &key, caches, suppress, state, incoming).await
        }
    };

    // 4. A deferred event is deliberately *not* recorded: nothing was applied,
    //    so a re-delivery should be allowed to try again.
    if outcome != Outcome::Deferred {
        state.record_applied(incoming, target);
    }
    outcome
}

fn pr_key(ev: &RelayEvent) -> Option<(String, u64)> {
    Some((ev.repo.clone()?, ev.number?))
}

/// Drop a PR from the ledger and from every per-PR cache keyed to it.
///
/// Clearing the caches is not just hygiene: leaving `last_seen_updated` behind
/// would let a stale `review_state_cache` entry be served if the PR ever came
/// back, and both maps would otherwise grow without bound over a long daemon
/// session.
fn remove_candidate(caches: &mut QueueCaches, key: &(String, u64)) -> bool {
    let existed = caches.candidates.remove(key).is_some();
    caches.last_seen_updated.remove(key);
    caches.review_state_cache.remove(key);
    caches.head_sha_cache.lock().unwrap().remove(key);
    existed
}

/// I asked for changes: the PR leaves buckets 1 and 2 and does **not** enter
/// bucket 3, because [`has_new_activity`]'s 30-second window is not satisfied
/// by my own submission. It re-enters `changes_req` only when a later event or
/// poll shows the author moved. Zero GitHub calls.
///
/// [`has_new_activity`]: crate::data::perri_queue_native::has_new_activity
fn apply_leave_buckets_12(
    caches: &mut QueueCaches,
    key: &(String, u64),
    state: &mut TargetedState,
    incoming: Incoming<'_>,
) -> Outcome {
    // Second precision, `...Z` — `parse_epoch` (and therefore
    // `has_new_activity`) cannot read fractional seconds and would silently
    // treat the timestamp as epoch 0.
    let submitted_at = incoming
        .delivered_at
        .to_rfc3339_opts(SecondsFormat::Secs, true);
    let Some(c) = caches.candidates.get_mut(key) else {
        // Not a candidate — nothing in the snapshot to take out.
        return Outcome::Unchanged;
    };
    c.in_requested = false;
    c.in_needs_review = false;
    c.my_review = Some(("CHANGES_REQUESTED".to_owned(), Some(submitted_at.clone())));

    caches
        .review_state_cache
        .insert(key.clone(), ("CHANGES_REQUESTED".to_owned(), Some(submitted_at)));
    // Cache-coherence invariant: we learned a review state without observing
    // the PR's `updated_at`, so the pairing that lets `review_from_cache()`
    // serve this entry must be broken. Costs one `/reviews` call next poll.
    caches.last_seen_updated.remove(key);

    state.mark_touched(key, incoming);
    Outcome::Changed
}

/// Re-read check-runs for one SHA: **exactly one** non-search request.
///
/// Deliberately not `ci_state_for_sha` — a `ci.completed` event *means* the
/// SHA's rollup changed, so serving the terminal cache entry would return the
/// stale verdict the event just invalidated. The request is still
/// ETag-conditional, so a 304 costs no rate-limit budget.
async fn apply_ci_only(
    client: &GithubClient,
    repo: &str,
    sha: &str,
    caches: &mut QueueCaches,
    state: &mut TargetedState,
    incoming: Incoming<'_>,
) -> Outcome {
    let result = fetch_check_runs_state(
        client,
        repo,
        sha,
        &caches.endpoint_etags,
        &caches.endpoint_body_cache,
    )
    .await;
    caches
        .ci_state_cache
        .lock()
        .unwrap()
        .insert(sha.to_owned(), result);

    let (ci_state, actions_failed) = result;
    let mut changed = false;
    let mut touched: Vec<(String, u64)> = Vec::new();
    for (key, c) in caches.candidates.iter_mut() {
        if c.repo != repo || c.head_sha != sha {
            continue;
        }
        changed |= c.ci_state != ci_state || c.actions_failed != actions_failed;
        c.ci_state = ci_state;
        c.actions_failed = actions_failed;
        touched.push(key.clone());
    }
    for key in &touched {
        state.mark_touched(key, incoming);
    }

    if changed {
        Outcome::Changed
    } else {
        Outcome::Unchanged
    }
}

/// Settle one PR from a GraphQL probe plus (at most) one check-runs read.
async fn apply_probe(
    client: &GithubClient,
    me: &str,
    key: &(String, u64),
    caches: &mut QueueCaches,
    suppress: &Arc<Mutex<SuppressStore>>,
    state: &mut TargetedState,
    incoming: Incoming<'_>,
) -> Outcome {
    let (repo, number) = (key.0.as_str(), key.1);
    match probe_pr(client, repo, number, me).await {
        // No ledger write, no snapshot change, no full refresh. The poll owns
        // it — this is the whole point of having no immediate fallback.
        ProbeResult::Failed => {
            debug!(
                %repo, number,
                event_type = %incoming.ev.event_type,
                "perri targeted: probe unusable — deferring to the periodic poll"
            );
            Outcome::Deferred
        }
        // Same verdict `get_pr_head_sha` reaches for a terminal PR.
        ProbeResult::Terminal => {
            state.mark_touched(key, incoming);
            if remove_candidate(caches, key) {
                Outcome::Changed
            } else {
                Outcome::Unchanged
            }
        }
        ProbeResult::Open(probed) => {
            let was_known = caches.candidates.contains_key(key);
            clear_superseded_suppression(suppress, repo, number, &probed.head_sha);

            let (ci_state, actions_failed) =
                ci_for_probed_head(client, caches, repo, number, &probed.head_sha).await;

            upsert_from_probe(caches, &probed, ci_state, actions_failed);

            // A PR that doesn't belong in any bucket and wasn't a candidate
            // before is not ours: `pr.opened` fires for every PR in the org, and
            // keeping them all would grow the ledger with noise *and* turn
            // every subsequent `ci.completed` on their heads into a paid
            // `CiOnly` read instead of a free `Ignore`.  Probing was the cost of
            // finding out; the ledger doesn't have to remember the answer.
            //
            // A PR that *was* known stays even when it no longer qualifies —
            // the full fetch records dropped candidates too, and a candidate
            // hidden only by a red CI must remain so a later `ci.completed` can
            // bring it back.
            if !was_known && !qualifies(caches, key, me) {
                remove_candidate(caches, key);
                debug!(
                    %repo, number,
                    "perri targeted: probed PR belongs in no bucket — not a candidate"
                );
                return Outcome::Unchanged;
            }

            state.mark_touched(key, incoming);
            Outcome::Changed
        }
    }
}

/// Resolve CI for a head SHA a probe just observed.
///
/// CI has exactly one implementation, shared with the full fetch — including the
/// ETag cache, the `ci_state_cache`, and the Actions-failure filter. Costs zero
/// extra requests when the SHA's state is already cached terminal.
///
/// An unresolved SHA is the one case we don't read: `/commits//check-runs` would
/// be a guaranteed 404. `(Unknown, false)` is exactly what the full fetch
/// records when it can't resolve a head either.
pub(crate) async fn ci_for_probed_head(
    client: &GithubClient,
    caches: &QueueCaches,
    repo: &str,
    number: u64,
    head_sha: &str,
) -> (CiState, bool) {
    if head_sha.is_empty() {
        return (CiState::Unknown, false);
    }
    ci_state_for_sha(
        client,
        repo,
        number,
        head_sha,
        &caches.head_sha_cache,
        &caches.ci_state_cache,
        &caches.endpoint_etags,
        &caches.endpoint_body_cache,
    )
    .await
}

/// Does this ledger entry belong in the snapshot on its own merits?
///
/// Delegates to the full fetch's own [`classify_bucket`] — the targeted path
/// must never carry a second copy of the bucket rules.
fn qualifies(caches: &QueueCaches, key: &(String, u64), me: &str) -> bool {
    caches
        .candidates
        .get(key)
        .is_some_and(|c| classify_bucket(c, me).is_some())
}

/// Drop an approval-suppression entry recorded against a superseded HEAD SHA.
///
/// `is_suppressed()` already declines to hide the PR (it matches SHAs exactly),
/// so this changes nothing now — it stops a force-push *back* to the approved
/// SHA from silently re-suppressing a PR whose approval no longer stands.
fn clear_superseded_suppression(
    suppress: &Arc<Mutex<SuppressStore>>,
    repo: &str,
    number: u64,
    head_sha: &str,
) {
    let mut store = suppress.lock().unwrap();
    let superseded = store
        .recorded_sha(repo, number)
        .is_some_and(|recorded| recorded != head_sha);
    if superseded && store.clear(repo, number) {
        debug!(%repo, number, "perri targeted: cleared suppression keyed to a superseded head SHA");
        store.save();
    }
}

/// Write a probe's verdict into the ledger and the per-PR caches, atomically
/// from the queue's point of view (no `.await` between the reads and writes).
///
/// A PR the ledger has not seen is **tail-appended**. That is
/// behaviour-preserving because every consumer groups or sorts by `bucket`, and
/// the next full poll re-derives canonical order.
pub(crate) fn upsert_from_probe(
    caches: &mut QueueCaches,
    probed: &ProbedPr,
    ci_state: CiState,
    actions_failed: bool,
) {
    let key = (probed.repo.clone(), probed.number);
    let seq = match caches.candidates.get(&key) {
        Some(existing) => existing.seq,
        None => {
            let seq = caches.next_seq;
            caches.next_seq += 1;
            seq
        }
    };

    caches.candidates.insert(
        key.clone(),
        Candidate {
            repo: probed.repo.clone(),
            number: probed.number,
            seq,
            title: probed.title.clone(),
            url: probed.url.clone(),
            is_bot: is_bot(&probed.author),
            author: probed.author.clone(),
            draft: probed.draft,
            updated_at: Some(probed.updated_at.clone()),
            head_sha: probed.head_sha.clone(),
            ci_state,
            actions_failed,
            in_requested: probed.in_requested,
            in_needs_review: probed.in_needs_review,
            my_review: probed.my_review.clone(),
            targeted_seen_at: Some(unix_now_secs()),
        },
    );

    // Cache-coherence invariant: `review_from_cache()` serves
    // `review_state_cache[k]` only while `last_seen_updated[k]` equals the PR's
    // `updated_at`. The probe observed both in the same read, so it may write
    // both. (When we have no review on the PR, the cache entry is *removed* —
    // an absent entry costs one `/reviews` call next poll and cannot lie.)
    match &probed.my_review {
        Some(review) => {
            caches.review_state_cache.insert(key.clone(), review.clone());
        }
        None => {
            caches.review_state_cache.remove(&key);
        }
    }
    caches
        .last_seen_updated
        .insert(key, probed.updated_at.clone());
}

// ── The GraphQL probe ─────────────────────────────────────────────────────────

/// One PR, as a probe sees it.
#[derive(Debug, Clone)]
pub struct ProbedPr {
    pub repo: String,
    pub number: u64,
    pub title: String,
    pub url: String,
    /// REST-shaped login (see [`normalise_login`]).
    pub author: String,
    pub draft: bool,
    pub updated_at: String,
    pub head_sha: String,
    /// `review-requested:@me` — bucket 1.
    pub in_requested: bool,
    /// `review:required` — bucket 2, from `reviewDecision`.
    pub in_needs_review: bool,
    /// Our most recent review, as `(state, submitted_at)`.
    pub my_review: Option<(String, Option<String>)>,
}

/// The outcome of a probe.
#[derive(Debug, Clone)]
pub enum ProbeResult {
    Open(Box<ProbedPr>),
    /// Closed or merged — the same verdict `get_pr_head_sha` reaches.
    Terminal,
    /// Transport error, non-2xx, a GraphQL `errors` array, or a null PR.
    Failed,
}

/// One PR, one point of the 5000/hour GraphQL budget, zero search budget.
///
/// Deliberate choices, each of which prevents a divergence from the full fetch:
///
/// * **No `statusCheckRollup`.** CI is resolved from `headRefOid` through
///   `ci_state_for_sha`, so the display state, the Actions-failure filter and
///   both caches are shared with the full fetch rather than reimplemented.
/// * **`reviews(last: 100)`, not `latestReviews`.** This mirrors
///   `get_our_last_review`'s "last review by me wins" exactly;
///   `latestReviews` has different per-author semantics.
/// * **`reviewRequests` team entries are ignored.** The full fetch uses
///   `review-requested:@me`, which does not match team requests either
///   (`team-review-requested:` is a separate qualifier). The poll heals them.
const PR_PROBE_QUERY: &str = r#"query PrProbe($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number
      title
      url
      isDraft
      state
      merged
      updatedAt
      headRefOid
      reviewDecision
      author { login __typename }
      reviewRequests(first: 100) {
        nodes {
          requestedReviewer {
            __typename
            ... on User { login }
            ... on Team { slug }
          }
        }
      }
      reviews(last: 100) {
        nodes { state submittedAt author { login } }
      }
    }
  }
}"#;

/// Read one PR's queue-relevant state over GraphQL.
///
/// Uses the raw `reqwest` client and [`api_base`] rather than `octocrab` so
/// tests can redirect it with `API_BASE_OVERRIDE`.
pub async fn probe_pr(client: &GithubClient, repo: &str, number: u64, me: &str) -> ProbeResult {
    let Some((owner, name)) = repo.split_once('/') else {
        debug!(%repo, "perri targeted: probe repo is not owner/name");
        return ProbeResult::Failed;
    };

    let payload = serde_json::json!({
        "query": PR_PROBE_QUERY,
        "variables": { "owner": owner, "name": name, "number": number },
    });

    let resp = match client
        .http
        .post(format!("{}/graphql", api_base()))
        .headers(base_headers(client))
        .json(&payload)
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            debug!(%repo, number, "perri targeted: probe request failed: {e:#}");
            return ProbeResult::Failed;
        }
    };

    if !resp.status().is_success() {
        debug!(%repo, number, status = %resp.status(), "perri targeted: probe non-2xx");
        return ProbeResult::Failed;
    }

    let body = match resp.text().await {
        Ok(b) => b,
        Err(e) => {
            debug!(%repo, number, "perri targeted: probe body read failed: {e:#}");
            return ProbeResult::Failed;
        }
    };

    let parsed: GqlResponse = match serde_json::from_str(&body) {
        Ok(p) => p,
        Err(e) => {
            debug!(%repo, number, "perri targeted: probe response unparseable: {e:#}");
            return ProbeResult::Failed;
        }
    };

    // A partial GraphQL response (200 + `errors`) is not a verdict.
    if parsed.errors.as_ref().is_some_and(|e| !e.is_empty()) {
        debug!(%repo, number, "perri targeted: probe returned GraphQL errors");
        return ProbeResult::Failed;
    }

    let Some(pr) = parsed
        .data
        .and_then(|d| d.repository)
        .and_then(|r| r.pull_request)
    else {
        debug!(%repo, number, "perri targeted: probe found no such pull request");
        return ProbeResult::Failed;
    };

    if pr.merged || pr.state != "OPEN" {
        return ProbeResult::Terminal;
    }

    let author = pr
        .author
        .as_ref()
        .map(|a| normalise_login(&a.login, a.typename.as_deref().unwrap_or("")))
        .unwrap_or_default();

    let in_requested = pr
        .review_requests
        .into_iter()
        .flat_map(|rr| rr.nodes.unwrap_or_default())
        .flatten()
        .filter_map(|node| node.requested_reviewer)
        .any(|reviewer| {
            reviewer.typename.as_deref() == Some("User")
                && reviewer.login.as_deref().is_some_and(|l| logins_match(l, me))
        });

    // "Last review by me wins" — the same rule as `get_our_last_review`'s
    // `rfind`, over the same window now that both request 100 reviews.
    let mut mine: Vec<GqlReviewNode> = pr
        .reviews
        .into_iter()
        .flat_map(|r| r.nodes.unwrap_or_default())
        .flatten()
        .filter(|node| {
            node.author
                .as_ref()
                .is_some_and(|a| logins_match(&a.login, me))
        })
        .collect();
    let my_review = mine.pop().map(|node| (node.state, node.submitted_at));

    ProbeResult::Open(Box::new(ProbedPr {
        repo: repo.to_owned(),
        number: pr.number,
        title: pr.title,
        url: pr.url,
        author,
        draft: pr.is_draft,
        updated_at: pr.updated_at,
        head_sha: pr.head_ref_oid,
        in_requested,
        // The per-PR equivalent of the `review:required` search qualifier.
        in_needs_review: pr.review_decision.as_deref() == Some("REVIEW_REQUIRED"),
        my_review,
    }))
}

/// GraphQL's `Bot.login` omits the `[bot]` suffix REST adds. Normalise so the
/// targeted path produces the same `author` string — and therefore the same
/// `is_bot` verdict and the same displayed author — as the full fetch.
pub fn normalise_login(login: &str, typename: &str) -> String {
    if typename == "Bot" && !login.ends_with("[bot]") {
        format!("{login}[bot]")
    } else {
        login.to_owned()
    }
}

/// Compare two GitHub logins, tolerating the `[bot]` suffix one side may carry.
/// GitHub logins are case-insensitive.
pub fn logins_match(a: &str, b: &str) -> bool {
    fn key(s: &str) -> String {
        s.trim_end_matches("[bot]").to_ascii_lowercase()
    }
    key(a) == key(b)
}

#[derive(Deserialize)]
struct GqlResponse {
    #[serde(default)]
    data: Option<GqlData>,
    #[serde(default)]
    errors: Option<Vec<serde_json::Value>>,
}

#[derive(Deserialize)]
struct GqlData {
    #[serde(default)]
    repository: Option<GqlRepository>,
}

#[derive(Deserialize)]
struct GqlRepository {
    #[serde(default, rename = "pullRequest")]
    pull_request: Option<GqlPullRequest>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GqlPullRequest {
    number: u64,
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: String,
    #[serde(default)]
    is_draft: bool,
    #[serde(default = "open_state")]
    state: String,
    #[serde(default)]
    merged: bool,
    #[serde(default)]
    updated_at: String,
    #[serde(default)]
    head_ref_oid: String,
    #[serde(default)]
    review_decision: Option<String>,
    #[serde(default)]
    author: Option<GqlActor>,
    #[serde(default)]
    review_requests: Option<GqlReviewRequests>,
    #[serde(default)]
    reviews: Option<GqlReviews>,
}

fn open_state() -> String {
    "OPEN".to_owned()
}

#[derive(Deserialize)]
struct GqlActor {
    #[serde(default)]
    login: String,
    #[serde(default, rename = "__typename")]
    typename: Option<String>,
}

#[derive(Deserialize)]
struct GqlReviewRequests {
    #[serde(default)]
    nodes: Option<Vec<Option<GqlReviewRequestNode>>>,
}

#[derive(Deserialize)]
struct GqlReviewRequestNode {
    #[serde(default, rename = "requestedReviewer")]
    requested_reviewer: Option<GqlRequestedReviewer>,
}

#[derive(Deserialize)]
struct GqlRequestedReviewer {
    #[serde(default, rename = "__typename")]
    typename: Option<String>,
    #[serde(default)]
    login: Option<String>,
    /// Team requests are read and deliberately discarded — see
    /// [`PR_PROBE_QUERY`].
    #[serde(default)]
    #[allow(dead_code)]
    slug: Option<String>,
}

#[derive(Deserialize)]
struct GqlReviews {
    #[serde(default)]
    nodes: Option<Vec<Option<GqlReviewNode>>>,
}

#[derive(Deserialize)]
struct GqlReviewNode {
    #[serde(default)]
    state: String,
    #[serde(default, rename = "submittedAt")]
    submitted_at: Option<String>,
    #[serde(default)]
    author: Option<GqlActor>,
}

// ── The divergence audit ──────────────────────────────────────────────────────

/// One field on which the poll and the targeted path disagree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Divergence {
    pub repo: String,
    pub number: u64,
    /// `presence` | `bucket` | `new_activity` | `ci_state` | `head_sha`.
    pub field: &'static str,
    pub poll: String,
    pub targeted: String,
}

/// Compare the targeted-maintained snapshot against a fresh poll's, for the
/// PRs a targeted update touched since the last poll.
///
/// **No GitHub request** — this is an in-memory diff of two item lists the
/// daemon already has.
///
/// Restricting to `audit_set` is what makes the result meaningful: any *other*
/// PR that differs differs because GitHub changed, not because the targeted
/// path was wrong.
///
/// One accepted false-positive source remains: a real GitHub change to an
/// audited PR between the targeted update and the poll. It is bounded to ≤60
/// seconds and to touched PRs, which is why the log is a `warn` to investigate
/// rather than an assertion.
pub fn diff_snapshots(
    targeted: &[PrQueueItem],
    poll: &[PrQueueItem],
    audit_set: &HashSet<(String, u64)>,
) -> Vec<Divergence> {
    fn index(items: &[PrQueueItem]) -> HashMap<(String, u64), &PrQueueItem> {
        items
            .iter()
            .map(|i| ((i.repo.clone(), i.number), i))
            .collect()
    }
    let before = index(targeted);
    let after = index(poll);

    // Deterministic order so the log (and the tests) don't depend on hashing.
    let mut keys: Vec<&(String, u64)> = audit_set.iter().collect();
    keys.sort();

    let mut out = Vec::new();
    for key in keys {
        let mut push = |field: &'static str, poll: String, targeted: String| {
            out.push(Divergence {
                repo: key.0.clone(),
                number: key.1,
                field,
                poll,
                targeted,
            });
        };
        match (before.get(key), after.get(key)) {
            (None, None) => {}
            (Some(_), None) => push("presence", "absent".to_owned(), "present".to_owned()),
            (None, Some(_)) => push("presence", "present".to_owned(), "absent".to_owned()),
            (Some(t), Some(p)) => {
                if t.bucket != p.bucket {
                    push("bucket", p.bucket.clone(), t.bucket.clone());
                }
                if t.new_activity != p.new_activity {
                    push(
                        "new_activity",
                        p.new_activity.to_string(),
                        t.new_activity.to_string(),
                    );
                }
                if t.ci_state != p.ci_state {
                    push(
                        "ci_state",
                        format!("{:?}", p.ci_state),
                        format!("{:?}", t.ci_state),
                    );
                }
                if t.head_sha != p.head_sha {
                    push("head_sha", p.head_sha.clone(), t.head_sha.clone());
                }
            }
        }
    }
    out
}
