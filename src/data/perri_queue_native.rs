//! Perri PR queue native data source — uses GitHub API directly.
//!
//! Implements the same three-bucket logic as `~/.claude/lib/perri/render-queue.sh`:
//!
//!   1. **`requested`**    — `review-requested:@me org:Carefeed`
//!   2. **`needs_review`** — `review:required org:Carefeed` (deduplicated against bucket 1)
//!   3. **`changes_req`**  — `reviewed-by:@me org:Carefeed`, filtered to CHANGES_REQUESTED
//!      reviews where the PR was updated >30 s after our review
//!      (i.e. the author has responded)
//!
//! PRs are excluded if:
//!   - They are drafts
//!   - The author is the authenticated user
//!   - The author is a bot (dependabot, carefeed-ci)
//!   - Any GitHub Actions check suite on the HEAD commit has `conclusion = "failure"`
//!
//! The two search queries for buckets 1 & 2 use ETags so a 304 Not Modified
//! response reuses the in-memory cache without re-processing.
//!
//! # Shape of a fetch
//!
//! Everything the queue remembers between cycles lives in [`QueueCaches`].
//! A fetch runs the three searches, records what they returned in the
//! **candidate ledger** ([`Candidate`]) — including PRs it will go on to drop —
//! resolves CI and review state for the candidates that warrant a read, and
//! then renders the ledger into the snapshot via [`render_items`]/[`classify`].
//!
//! The ledger records dropped candidates on purpose: a PR hidden by the
//! CI-failure filter or by approval suppression is still a PR the queue knows
//! about, and re-rendering it later must not require re-running a search.
//!
//! Which candidates get a GitHub read is behaviour, not an optimisation
//! detail: drafts, self-authored PRs, and bucket-3 candidates that fail the
//! review-state or new-activity gate cost **zero** requests, and the queue's
//! tests measure that.
//!
//! # Wake sources, and the two update paths
//!
//! [`wait_for_wake`] waits on the poll interval, the dirty-file sentinel, the
//! MCP direct-push channel, the approvals-file watcher, and the typed
//! github-relay channel, and returns a [`Wake`] saying which of two things to
//! do:
//!
//! * [`Wake::Full`] — the fetch described above. Produced by the interval, the
//!   dirty file, the MCP push, the approvals file, and a relay *(re)connect*
//!   (the relay buffers nothing for an absent subscriber, so a reconnect is a
//!   reconciliation and there is no event describing it). A reconnect's own
//!   events are carried in `Wake::Full`'s `deferred` field: the reconciling
//!   fetch runs first, then `deferred` is applied as the very next wake — a
//!   reconnect reconciles first, then applies the batch.
//! * [`Wake::Targeted`] — a batch of relay events, each applied to a single PR
//!   by [`perri_queue_targeted`], with **zero** search requests. No relay
//!   *event* produces a full refresh; an event that can't be settled from
//!   scoped reads changes nothing and is left to the next poll.
//!
//! The poll is therefore not a legacy path but the floor under the targeted
//! one. It is the correctness backstop — relay delivery is at-most-once with no
//! backfill, and real queue changes (suppression expiry, draft toggles, team
//! review requests, branch-protection changes) arrive with no event at all —
//! *and* the audit vantage point: after each poll, every PR a targeted update
//! touched since the last one is diffed against the fresh verdict and any
//! disagreement is logged at `warn` (see `audit_divergence`).
//!
//! `perri_targeted_relay = false` in the config turns the targeted path off
//! entirely, restoring the pre-engine behaviour.
//!
//! [`perri_queue_targeted`]: crate::data::perri_queue_targeted

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use anyhow::{Context, Result};
use chrono::Utc;
use reqwest::header::{HeaderMap, ACCEPT, AUTHORIZATION, IF_NONE_MATCH};
use serde::Deserialize;
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{
    config::Config,
    data::{
        dirty_file,
        github_client::GithubClient,
        perri_pr_native::prefetch_into_cache,
        perri_queue::{CiState, PrQueueItem, PrQueueSnapshot},
        perri_queue_targeted::{
            apply_relay_event, diff_snapshots, probe_and_upsert, qualifies, remove_candidate,
            ProbeResult, TargetedState,
        },
        perri_suppress::{unix_now_secs, SuppressStore},
        relay_client::{QueueSignal, RelayEvent},
    },
};

// ── Test-injectable API base URL ─────────────────────────────────────────────
//
// The thread-local is always compiled so that integration tests (which link
// against the library as a separate crate) can set it.  In normal operation it
// is never set, so `api_base()` returns the real GitHub URL.

thread_local! {
    /// Override the GitHub API base URL for tests.  Leave `None` in production.
    pub static API_BASE_OVERRIDE: std::cell::RefCell<Option<String>> =
        const { std::cell::RefCell::new(None) };
}

pub(crate) fn api_base() -> String {
    API_BASE_OVERRIDE.with(|o| {
        o.borrow()
            .clone()
            .unwrap_or_else(|| "https://api.github.com".to_owned())
    })
}

// ── GitHub API response shapes ────────────────────────────────────────────────

#[derive(Deserialize)]
struct SearchResponse {
    items: Vec<SearchIssueItem>,
}

#[derive(Deserialize, Clone)]
pub struct SearchIssueItem {
    number: u64,
    title: String,
    html_url: String,
    repository_url: String,
    user: Option<GhUser>,
    draft: Option<bool>,
    updated_at: Option<String>,
}

#[derive(Deserialize, Clone)]
pub struct GhUser {
    login: String,
}

#[derive(Deserialize)]
struct AuthenticatedUser {
    login: String,
}

#[derive(Deserialize)]
struct ReviewItem {
    state: String,
    submitted_at: Option<String>,
    user: Option<GhUser>,
}

// ── Check-runs API response shapes ───────────────────────────────────────────

#[derive(Deserialize)]
struct CheckRunsResponse {
    check_runs: Vec<CheckRun>,
}

#[derive(Deserialize)]
struct CheckRun {
    status: Option<String>,
    conclusion: Option<String>,
    app: Option<CheckRunApp>,
}

#[derive(Deserialize)]
struct CheckRunApp {
    slug: Option<String>,
}

// ── Legacy check-suites shapes (kept for fetch_check_suites_failure) ─────────

#[derive(Deserialize)]
struct CheckSuitesResponse {
    check_suites: Vec<CheckSuite>,
}

#[derive(Deserialize)]
struct CheckSuite {
    app: Option<AppInfo>,
    conclusion: Option<String>,
}

#[derive(Deserialize)]
struct AppInfo {
    name: String,
}

#[derive(Deserialize)]
struct PrDetail {
    head: PrHead,
    /// `"open"`, `"closed"`, or `"merged"`.  `None` when the field is absent
    /// (older daemon-test mocks that predate this field).
    state: Option<String>,
    /// ISO-8601 timestamp set when the PR was merged; `None` for open PRs.
    merged_at: Option<String>,
}

#[derive(Deserialize)]
struct PrHead {
    sha: String,
}

/// Result of fetching a PR's HEAD SHA from the GitHub API.
enum GetPrHeadResult {
    /// PR is open; the `String` is the HEAD commit SHA.
    Open(String),
    /// PR is closed or merged — drop it from the queue regardless of search results.
    Terminal,
}

// ── Queue caches ──────────────────────────────────────────────────────────────

/// Every piece of mutable state the queue carries across fetch cycles, in one
/// place.
///
/// These were eight separate locals in `run()` threaded individually into
/// `fetch()`.  Bundling them means a caller that wants to update the queue
/// reads and writes *the same* state `fetch()` does — a property of the type
/// rather than a promise in a comment.
///
/// The four `Arc<Mutex<…>>` members are shared with the concurrent per-PR
/// futures inside `fetch()`'s `join_all`, which is why they are not plain
/// maps.  The rest are only touched from the single fetch driver.
///
/// Note: the authenticated user login (`me`) is deliberately *not* here — it is
/// a one-shot identity lookup, not a cache the queue mutates per cycle.
#[derive(Default)]
pub struct QueueCaches {
    /// ETag cache per search query string.
    pub etags: HashMap<String, String>,
    /// Item cache per search query (for 304 reuse).
    pub item_cache: HashMap<String, Vec<SearchIssueItem>>,
    /// `updated_at` seen on last fetch per (repo, number) — used to skip review
    /// re-fetches.
    pub last_seen_updated: HashMap<(String, u64), String>,
    /// Cached last review state per (repo, number).
    pub review_state_cache: HashMap<(String, u64), (String, Option<String>)>,
    /// Last-known HEAD SHA per (repo, number).  Persists across loop iterations
    /// so successive cycles skip the check-runs call when HEAD hasn't moved.
    pub head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>>,
    /// Maps HEAD SHA → (display CiState, Actions-failure filter bool).
    pub ci_state_cache: Arc<Mutex<HashMap<String, (CiState, bool)>>>,
    /// ETag cache for per-endpoint conditional GETs (get_pr_head_sha,
    /// fetch_check_runs_state, get_our_last_review).  Keyed by full URL so a
    /// single map covers all three endpoints without collisions.
    pub endpoint_etags: Arc<Mutex<HashMap<String, String>>>,
    /// Response-body cache paired with `endpoint_etags`, same keying.
    pub endpoint_body_cache: Arc<Mutex<HashMap<String, String>>>,
    /// The candidate ledger — every PR the last fetch's searches returned,
    /// *including* ones the CI filter or approval suppression hide.  New state:
    /// it replaces nothing that existed before.
    pub candidates: HashMap<(String, u64), Candidate>,
    /// Monotonic insertion counter feeding `Candidate::seq`.
    pub next_seq: u64,
    /// PRs the last fetch carried over because the search index hadn't caught
    /// up with a targeted probe yet.  The divergence audit exempts them: their
    /// difference from the poll's raw verdict is explained, not drift.
    pub last_grace_retained: HashSet<(String, u64)>,
}

/// How long a targeted probe's verdict outlives a search that doesn't confirm
/// it: two poll cycles.  Long enough for GitHub's index to catch up, short
/// enough that a wrong probe cannot linger.
const SEARCH_LAG_GRACE_SECS: u64 = 120;

/// At most this many grace re-probes per poll, so a pathological ledger can't
/// turn one poll into a probe storm.  Oldest probe first.
const SEARCH_LAG_GRACE_MAX: usize = 5;

/// Which ledger entries a fresh set of search results failed to confirm, but
/// which a targeted probe vouched for recently enough to deserve a re-probe.
fn collect_search_lag_candidates(
    candidates: &HashMap<(String, u64), Candidate>,
    requested: &[SearchIssueItem],
    needs: &[SearchIssueItem],
    reviewed: &[SearchIssueItem],
    now_secs: u64,
) -> Vec<(String, u64, u64)> {
    let returned: HashSet<(String, u64)> = requested
        .iter()
        .chain(needs)
        .chain(reviewed)
        .map(|i| (repo_from_url(&i.repository_url), i.number))
        .collect();

    // Sorted by `targeted_seen_at` ascending, so the cap below drops the
    // *newest* — those have the most grace left to spend on a later poll.
    let mut fresh: Vec<(u64, (String, u64))> = candidates
        .iter()
        .filter(|(key, _)| !returned.contains(*key))
        .filter_map(|(key, c)| {
            let seen_at = c.targeted_seen_at?;
            (now_secs.saturating_sub(seen_at) <= SEARCH_LAG_GRACE_SECS)
                .then(|| (seen_at, key.clone()))
        })
        .collect();

    fresh.sort();
    if fresh.len() > SEARCH_LAG_GRACE_MAX {
        debug!(
            dropped = fresh.len() - SEARCH_LAG_GRACE_MAX,
            "perri queue: search-lag grace cap reached — some recently-probed candidates dropped"
        );
        fresh.truncate(SEARCH_LAG_GRACE_MAX);
    }
    fresh
        .into_iter()
        .map(|(seen_at, (repo, number))| (repo, number, seen_at))
        .collect()
}

/// One PR the queue knows about, and everything needed to decide whether it
/// belongs in the snapshot — without re-running a search.
///
/// A candidate is recorded whether or not it ships: drafts, self-authored PRs,
/// CI-failed PRs and suppressed PRs all get entries.  [`classify`] is what
/// turns an entry into a [`PrQueueItem`] or into nothing.
pub struct Candidate {
    pub repo: String,
    pub number: u64,
    /// Insertion order, which is snapshot order.
    pub seq: u64,
    pub title: String,
    pub url: String,
    /// REST-shaped login; empty string when the search item had no user.
    pub author: String,
    pub is_bot: bool,
    pub draft: bool,
    pub updated_at: Option<String>,
    /// Empty until a CI read resolves it.
    pub head_sha: String,
    pub ci_state: CiState,
    /// The CI drop filter — a GitHub Actions run concluded `failure`, or the
    /// PR turned out to be closed/merged.
    pub actions_failed: bool,
    /// Seen in `review-requested:@me` (bucket 1).
    pub in_requested: bool,
    /// Seen in `review:required` (bucket 2).
    pub in_needs_review: bool,
    /// Our most recent review on this PR, as `(state, submitted_at)`.
    pub my_review: Option<(String, Option<String>)>,
    /// Unix seconds of the last targeted probe that wrote this entry, or
    /// `None` if it was written only by a search hit.
    ///
    /// This is what drives the [`SEARCH_LAG_GRACE_SECS`] carry-over window in
    /// [`collect_search_lag_candidates`]: a candidate a targeted probe vouched
    /// for recently enough survives a poll whose search results don't (yet)
    /// confirm it. The non-obvious part is that [`apply_search_lag_grace`]
    /// preserves the *original* stamp across a re-probe rather than re-stamping
    /// it — re-stamping would re-arm the grace window on every poll and let a
    /// PR the search index never confirms be carried forever instead of for two
    /// cycles.
    pub targeted_seen_at: Option<u64>,
}

impl Candidate {
    /// Record a PR discovered by a search, if it isn't in the ledger already.
    ///
    /// First discovery wins for the descriptive fields *and* for `seq`, so a PR
    /// found by two searches keeps the position of the bucket that found it
    /// first — which is how bucket 1 takes priority over bucket 2.
    fn upsert<'a>(
        candidates: &'a mut HashMap<(String, u64), Candidate>,
        next_seq: &mut u64,
        repo: String,
        item: &SearchIssueItem,
    ) -> &'a mut Candidate {
        let key = (repo.clone(), item.number);
        candidates.entry(key).or_insert_with(|| {
            let author = item
                .user
                .as_ref()
                .map(|u| u.login.clone())
                .unwrap_or_default();
            let seq = *next_seq;
            *next_seq += 1;
            Candidate {
                repo,
                number: item.number,
                seq,
                title: item.title.clone(),
                url: item.html_url.clone(),
                is_bot: is_bot(&author),
                author,
                draft: item.draft.unwrap_or(false),
                updated_at: item.updated_at.clone(),
                head_sha: String::new(),
                ci_state: CiState::Unknown,
                actions_failed: false,
                in_requested: false,
                in_needs_review: false,
                my_review: None,
                targeted_seen_at: None,
            }
        })
    }
}

/// The bucket verdict for a ledger entry: `(bucket, new_activity)`, or `None`
/// if the PR doesn't belong in the snapshot on its own merits.
///
/// This is everything [`classify`] decides *except* approval suppression, which
/// is time-dependent and therefore separable.  The order of the checks is the
/// behaviour; changing it changes the queue.
pub fn classify_bucket(c: &Candidate, me: &str) -> Option<(&'static str, bool)> {
    // 1. Drafts and our own PRs are never ours to review (`is_filtered`).
    //    Bots are deliberately *not* excluded here — they get their own bucket.
    if c.draft || c.author == me {
        return None;
    }

    // 2. The CI drop filter.
    if c.actions_failed {
        return None;
    }

    // 3. Bucket precedence.  `qualifies_b3` is the bucket-3 gate: we asked for
    //    changes and the author has since responded.
    let qualifies_b3 = c.my_review.as_ref().is_some_and(|(state, submitted_at)| {
        state == "CHANGES_REQUESTED"
            && has_new_activity(submitted_at.as_deref(), c.updated_at.as_deref())
    });
    if c.is_bot && (c.in_requested || c.in_needs_review || qualifies_b3) {
        Some(("dependabot", false))
    } else if c.in_requested {
        Some(("requested", false))
    } else if c.in_needs_review {
        Some(("needs_review", false))
    } else if qualifies_b3 {
        Some(("changes_req", true))
    } else {
        None
    }
}

/// Render one ledger entry into a queue item, or `None` if it doesn't belong in
/// the snapshot.
pub fn classify(
    c: &Candidate,
    me: &str,
    suppress: &SuppressStore,
    now_secs: u64,
) -> Option<PrQueueItem> {
    let (bucket, new_activity) = classify_bucket(c, me)?;

    // Approval suppression, applied last.  An unresolved (empty) head_sha never
    // matches a recorded entry.
    if suppress.is_suppressed(&c.repo, c.number, &c.head_sha, now_secs) {
        return None;
    }

    Some(PrQueueItem {
        repo: c.repo.clone(),
        number: c.number,
        title: c.title.clone(),
        author: c.author.clone(),
        bucket: bucket.to_owned(),
        new_activity,
        url: c.url.clone(),
        ci_state: c.ci_state,
        head_sha: c.head_sha.clone(),
        is_bot: c.is_bot,
    })
}

/// What one bucket-3 probe learned about a PR, folded back into the ledger
/// after the concurrent probes join.
#[derive(Default)]
struct B3Outcome {
    key: (String, u64),
    /// Our last review on the PR, when the probe resolved one (from the cache
    /// or from the API).
    my_review: Option<(String, Option<String>)>,
    /// `(ci_state, actions_failed, head_sha)` — present only when the probe got
    /// far enough to read CI.
    ci: Option<(CiState, bool, String)>,
    /// A review-state cache entry to write back, when the API was called.
    new_cache_entry: Option<(String, Option<String>)>,
}

/// Render the ledger with the live suppression store: prune expired entries
/// (persisting if anything went), then render.
///
/// Both publish paths go through this so a targeted publish can never resurrect
/// a suppression the full fetch would have pruned, or hide a PR the full fetch
/// would have shown.  One lock acquisition covers the prune and the render.
pub fn render_with_suppression(
    caches: &QueueCaches,
    me: &str,
    suppress: &Arc<Mutex<SuppressStore>>,
) -> Vec<PrQueueItem> {
    let now = unix_now_secs();
    let mut store = suppress.lock().unwrap();
    if store.prune(now) {
        store.save();
    }
    let suppressed = caches
        .candidates
        .values()
        .filter(|c| {
            classify_bucket(c, me).is_some()
                && store.is_suppressed(&c.repo, c.number, &c.head_sha, now)
        })
        .count();
    if suppressed > 0 {
        debug!("perri suppress: hid {suppressed} just-approved PR(s) from snapshot");
    }
    render_items(&caches.candidates, me, &store, now)
}

/// Render the whole ledger, in insertion order, into the snapshot's item list.
pub fn render_items(
    candidates: &HashMap<(String, u64), Candidate>,
    me: &str,
    suppress: &SuppressStore,
    now_secs: u64,
) -> Vec<PrQueueItem> {
    let mut ordered: Vec<&Candidate> = candidates.values().collect();
    ordered.sort_by_key(|c| c.seq);
    ordered
        .into_iter()
        .filter_map(|c| classify(c, me, suppress, now_secs))
        .collect()
}

// ── Source ────────────────────────────────────────────────────────────────────

pub struct PerriQueueNativeSource {
    config: Config,
}

impl PerriQueueNativeSource {
    /// Build a source without spawning its run loop — for tests and callers
    /// that want to drive one `fetch()` or one targeted update by hand.
    pub fn new(config: Config) -> Self {
        Self { config }
    }

    /// Spawn the data source.
    ///
    /// Returns `(snapshot_rx, refresh_tx, relay_tx)`.
    ///
    /// `refresh_tx` allows MCP tools to request an immediate queue re-fetch
    /// without touching the dirty-file sentinel (phase 4).
    ///
    /// `relay_tx` is the github-relay subscriber's channel.  A batch of events
    /// on it drives a *targeted* per-PR update that issues no search request; a
    /// (re)connect on it is the one relay signal that still forces a full
    /// refresh.  See the module docs.
    pub fn spawn(
        config: Config,
    ) -> (
        watch::Receiver<Option<PrQueueSnapshot>>,
        mpsc::UnboundedSender<()>,
        mpsc::UnboundedSender<QueueSignal>,
    ) {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();
        let (refresh_tx, mut refresh_rx) = mpsc::unbounded_channel::<()>();
        let (approvals_tx, mut approvals_rx) = mpsc::unbounded_channel::<()>();
        let (relay_tx, mut relay_rx) = mpsc::unbounded_channel::<QueueSignal>();

        let state_dir = config.perri_state_dir();
        let dirty_path = state_dir.join("queue.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        // Watch approvals.jsonl without deleting it — the daemon renames and
        // processes it atomically inside consume_approvals_file().
        let approvals_path = state_dir.join("approvals.jsonl");
        dirty_file::spawn_exists_watcher(approvals_path, approvals_tx);

        // Load the suppression store from disk so previously-recorded approvals
        // survive a daemon restart.
        let ttl = std::time::Duration::from_secs(config.pr_approval_suppress_secs);
        let state_path = state_dir.join("approvals-state.json");
        let suppress = Arc::new(Mutex::new(SuppressStore::load(state_path, ttl)));

        let interval_secs = config.pr_queue_poll_secs;

        tokio::spawn(async move {
            let source = PerriQueueNativeSource { config };
            source
                .run(
                    tx,
                    &mut dirty_rx,
                    &mut refresh_rx,
                    &mut approvals_rx,
                    &mut relay_rx,
                    suppress,
                    interval_secs,
                )
                .await;
        });

        (rx, refresh_tx, relay_tx)
    }

    #[allow(clippy::too_many_arguments)]
    async fn run(
        &self,
        tx: watch::Sender<Option<PrQueueSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
        refresh_rx: &mut mpsc::UnboundedReceiver<()>,
        approvals_rx: &mut mpsc::UnboundedReceiver<()>,
        relay_rx: &mut mpsc::UnboundedReceiver<QueueSignal>,
        suppress: Arc<Mutex<SuppressStore>>,
        interval_secs: u64,
    ) {
        let client = match self.build_client() {
            Ok(c) => c,
            Err(e) => {
                warn!("github client init failed: {e:#}");
                let _ = tx.send(Some(PrQueueSnapshot {
                    error: Some(format!("GitHub client init failed: {e:#}")),
                    stale: true,
                    ..Default::default()
                }));
                return;
            }
        };

        // All cross-cycle mutable queue state lives here (see `QueueCaches`).
        let mut caches = QueueCaches::default();
        // Dedup / ordering / audit bookkeeping for the targeted path.
        let mut tstate = TargetedState::default();
        // Authenticated user login — fetched once and reused.
        let mut me: Option<String> = None;

        // Path to the approvals JSONL signal file.
        let approvals_path = self.config.perri_state_dir().join("approvals.jsonl");
        let targeted_enabled = self.config.perri_targeted_relay;

        // The first pass is always a full fetch — a cold daemon has no ledger to
        // update, and every targeted action is defined relative to one.
        let mut wake = Wake::Full {
            reason: "startup",
            deferred: Vec::new(),
        };

        loop {
            let me_login = match &me {
                Some(m) => m.clone(),
                None => match get_authenticated_user(&client).await {
                    Ok(login) => {
                        me = Some(login.clone());
                        login
                    }
                    Err(e) => {
                        warn!("failed to get authenticated user: {e:#}");
                        let mut snap = tx.borrow().clone().unwrap_or_default();
                        snap.stale = true;
                        snap.error = Some(format!("GitHub auth check failed: {e:#}"));
                        let _ = tx.send(Some(snap));
                        tokio::time::sleep(std::time::Duration::from_secs(interval_secs)).await;
                        // A reconnect's deferred batch must survive an auth
                        // retry, exactly as the old `pending` local did. A
                        // targeted batch is still not replayed — the full
                        // refresh supersedes it.
                        let deferred = match &mut wake {
                            Wake::Full { deferred, .. } => std::mem::take(deferred),
                            Wake::Targeted(_) => Vec::new(),
                        };
                        wake = Wake::Full {
                            reason: "auth retry",
                            deferred,
                        };
                        continue;
                    }
                },
            };

            let next = match wake {
                Wake::Full { reason, deferred } => {
                    self.run_full_refresh(
                        &client,
                        &me_login,
                        &mut caches,
                        &suppress,
                        &mut tstate,
                        &tx,
                        &approvals_path,
                        reason,
                    )
                    .await;
                    // A reconnect's stashed events are applied on the very
                    // next iteration, so they are never silently dropped.
                    (!deferred.is_empty()).then_some(Wake::Targeted(deferred))
                }

                Wake::Targeted(events) => {
                    self.run_targeted_update(
                        &client,
                        &me_login,
                        &mut caches,
                        &suppress,
                        &mut tstate,
                        &tx,
                        events,
                    )
                    .await;
                    None
                }
            };

            if let Some(next) = next {
                wake = next;
                continue;
            }

            wake = wait_for_wake(
                dirty_rx,
                refresh_rx,
                approvals_rx,
                relay_rx,
                interval_secs,
                targeted_enabled,
            )
            .await;
        }
    }

    /// Re-derive the whole queue and publish it, auditing the targeted path
    /// against the result before the ledger it was measured against is gone.
    ///
    /// One `Wake::Full` arm of the run loop, pulled out only because `run()`
    /// otherwise buries this sequence — fetch, audit, prune, publish — inside
    /// a `match` alongside the targeted arm below.
    #[allow(clippy::too_many_arguments)]
    async fn run_full_refresh(
        &self,
        client: &GithubClient,
        me_login: &str,
        caches: &mut QueueCaches,
        suppress: &Arc<Mutex<SuppressStore>>,
        tstate: &mut TargetedState,
        tx: &watch::Sender<Option<PrQueueSnapshot>>,
        approvals_path: &Path,
        reason: &'static str,
    ) {
        // Consume any approvals that arrived since the last cycle (or since
        // startup).  Belt-and-suspenders: the approvals_rx wake also triggers
        // an immediate re-fetch when the file appears, but we consume here
        // unconditionally so a write that races past the watcher is never
        // missed.
        {
            let mut store = suppress.lock().unwrap();
            let count = store.consume_approvals_file(approvals_path, unix_now_secs());
            if count > 0 {
                store.save();
                debug!("perri suppress: consumed {count} new approval(s) before fetch");
            }
        }

        let prev = tx.borrow().clone();
        // Everything a targeted update claimed a verdict for since the last
        // poll.  Taken *before* the fetch so events that arrive during it are
        // audited by the *next* poll.
        let mut audit_set = std::mem::take(&mut tstate.touched_since_poll);

        debug!(reason, "perri queue full refresh");
        match self.fetch(client, me_login, caches, suppress).await {
            Ok(snap) => {
                // PRs the search-index-lag grace carried over differ from the
                // poll's raw verdict *by design*.
                for key in &caches.last_grace_retained {
                    audit_set.remove(key);
                }
                self.audit_divergence(&prev, &snap, &audit_set, tstate);
                tstate.prune(&caches.candidates);
                self.publish_snapshot(tx, client, snap, PrefetchScope::TopThree);
            }
            Err(e) => {
                warn!("perri queue fetch failed: {e:#}");
                // A failed poll audited nothing, so the set has to survive to
                // the next one — `extend`, not assign: targeted events may
                // have landed during the failed fetch.
                tstate.touched_since_poll.extend(audit_set);
                let mut snap = tx.borrow().clone().unwrap_or_default();
                snap.stale = true;
                snap.error = Some(e.to_string());
                let _ = tx.send(Some(snap));
            }
        }
    }

    /// Apply a batch of relay events to the ledger and publish only if one of
    /// them actually changed a verdict.
    ///
    /// The other `Wake` arm of the run loop, pulled out for the same reason as
    /// [`Self::run_full_refresh`].
    #[allow(clippy::too_many_arguments)]
    async fn run_targeted_update(
        &self,
        client: &GithubClient,
        me_login: &str,
        caches: &mut QueueCaches,
        suppress: &Arc<Mutex<SuppressStore>>,
        tstate: &mut TargetedState,
        tx: &watch::Sender<Option<PrQueueSnapshot>>,
        events: Vec<RelayEvent>,
    ) {
        // Bound to a local before the `.await`s below: the `watch::Ref` guard
        // `borrow()` returns is not `Send`.
        let current = tx.borrow().clone();
        let Some(current) = current.filter(|s| !s.stale && s.error.is_none()) else {
            // Nothing coherent to mutate.  The next full fetch settles
            // everything anyway, and mutating a broken ledger would only
            // publish a differently-wrong snapshot.
            debug!(
                events = events.len(),
                "perri targeted: no healthy snapshot — deferring to the periodic poll"
            );
            return;
        };

        let mut changed = false;
        for ev in &events {
            changed |= apply_relay_event(client, me_login, ev, caches, suppress, tstate)
                .await
                .is_changed();
        }

        if changed {
            let snap = PrQueueSnapshot {
                generated_at: Some(Utc::now()),
                items: render_with_suppression(caches, me_login, suppress),
                stale: false,
                error: None,
            };
            self.publish_snapshot(
                tx,
                client,
                snap,
                PrefetchScope::NewlyTopThree(&current.items),
            );
        }
    }

    /// Log every field on which a fresh poll disagrees with the
    /// targeted-maintained snapshot, for the PRs a targeted update touched.
    ///
    /// Issues **no** GitHub request: it is a diff of two item lists the daemon
    /// already holds.  Skipped when there is no prior snapshot, when the prior
    /// snapshot was stale or errored (there is nothing trustworthy to compare
    /// against), or when no targeted update has run since the last poll.
    pub fn audit_divergence(
        &self,
        prev: &Option<PrQueueSnapshot>,
        fresh: &PrQueueSnapshot,
        audit_set: &HashSet<(String, u64)>,
        tstate: &TargetedState,
    ) {
        if audit_set.is_empty() {
            return;
        }
        let Some(prev) = prev.as_ref().filter(|p| !p.stale && p.error.is_none()) else {
            return;
        };
        for d in diff_snapshots(&prev.items, &fresh.items, audit_set) {
            let last = tstate.last_event.get(&(d.repo.clone(), d.number));
            warn!(
                repo = %d.repo,
                number = d.number,
                field = d.field,
                poll_verdict = %d.poll,
                targeted_verdict = %d.targeted,
                last_event_type = last.map(|l| l.event_type.as_str()).unwrap_or("?"),
                last_event_id = last.map(|l| l.event_id.as_str()).unwrap_or("?"),
                last_event_at = last.map(|l| l.at.to_rfc3339()).unwrap_or_else(|| "?".to_owned()),
                "perri queue: targeted update diverged from periodic poll"
            );
        }
    }

    /// Publish a snapshot: write the on-disk queue cache, kick off detail
    /// prefetch, then hand the snapshot to the watch channel.
    ///
    /// Ordering matters — the cache file is written *before* the watch send so
    /// a reader woken by the send always finds a file that already matches.
    ///
    /// **Both** the full-refresh and the targeted paths publish through here, so
    /// no consumer can tell which one produced a snapshot.  They differ only in
    /// `scope`: a full refresh reconsiders the whole top 3, a targeted update
    /// only prefetches PRs that newly entered it.
    pub fn publish_snapshot(
        &self,
        tx: &watch::Sender<Option<PrQueueSnapshot>>,
        client: &GithubClient,
        snap: PrQueueSnapshot,
        scope: PrefetchScope<'_>,
    ) {
        debug!(prs = snap.items.len(), "perri queue refreshed");

        // Write the queue cache atomically so Swift reads a complete file.
        let state_dir = self.config.perri_state_dir();
        let cache_path = state_dir.join(".queue.cache.json");
        match serde_json::to_string(&snap) {
            Ok(json) => {
                if let Err(e) = write_json_atomic(&cache_path, &json) {
                    warn!("perri queue cache write failed: {e:#}");
                } else {
                    debug!("perri queue cache written: {}", cache_path.display());
                }
            }
            Err(e) => warn!("perri queue cache serialize failed: {e:#}"),
        }

        // Pre-fetch detail for the selected PRs in bucket-priority order.
        for item in prefetch_targets(&scope, &snap.items) {
            let cfg = self.config.clone();
            let client_clone = client.clone();
            let repo = item.repo.clone();
            let number = item.number;
            let sha = item.head_sha.clone();
            let sd = state_dir.clone();
            tokio::spawn(async move {
                // Skip if a fresh cache file already exists for this (repo, number, sha).
                if cache_is_fresh(&sd, &repo, number, &sha) {
                    debug!("perri prefetch {repo}#{number} cache fresh — skipping");
                    return;
                }
                if let Err(e) = prefetch_into_cache(&cfg, &client_clone, &repo, number).await {
                    debug!("perri prefetch {repo}#{number} failed: {e:#}");
                }
            });
        }

        let _ = tx.send(Some(snap));
    }

    /// Re-derive the whole queue from the three org-wide searches.
    ///
    /// `pub` so integration tests can drive one cycle directly; the daemon only
    /// ever calls it from `run()`.
    pub async fn fetch(
        &self,
        client: &GithubClient,
        me: &str,
        caches: &mut QueueCaches,
        suppress: &Arc<Mutex<SuppressStore>>,
    ) -> Result<PrQueueSnapshot> {
        // Owned handles to the shared caches, so the concurrent futures below
        // don't borrow `caches` (which the search/review paths need mutably).
        let head_sha_cache = Arc::clone(&caches.head_sha_cache);
        let ci_state_cache = Arc::clone(&caches.ci_state_cache);
        let endpoint_etags = Arc::clone(&caches.endpoint_etags);
        let endpoint_body_cache = Arc::clone(&caches.endpoint_body_cache);

        // ── Run the three search queries ──────────────────────────────────────
        let q_requested =
            "is:open is:pr review-requested:@me org:Carefeed archived:false".to_owned();
        let q_needs = "is:open is:pr review:required org:Carefeed archived:false".to_owned();
        let q_reviewed = "is:open is:pr reviewed-by:@me org:Carefeed archived:false".to_owned();

        // Searches must run sequentially because they share the mutable ETag
        // and item caches.  This is fine — the poll interval is 60s.
        let requested_items = search_issues(
            client,
            &q_requested,
            &mut caches.etags,
            &mut caches.item_cache,
        )
        .await?;
        let needs_items =
            search_issues(client, &q_needs, &mut caches.etags, &mut caches.item_cache).await?;
        let reviewed_items = search_issues(
            client,
            &q_reviewed,
            &mut caches.etags,
            &mut caches.item_cache,
        )
        .await?;

        debug!(
            me,
            requested = requested_items.len(),
            needs = needs_items.len(),
            reviewed = reviewed_items.len(),
            "perri queue search results"
        );

        // A PR a targeted probe added moments ago can be genuinely absent from
        // the search index (see `apply_search_lag_grace`).  Note which ones
        // *before* the ledger is replaced; they are re-probed at the end.
        let carried = collect_search_lag_candidates(
            &caches.candidates,
            &requested_items,
            &needs_items,
            &reviewed_items,
            unix_now_secs(),
        );

        // The ledger describes *this* fetch's search results — a PR the searches
        // no longer return is gone, not stale.  Replace, don't merge.
        caches.candidates.clear();

        // ── Record bucket 1 & 2 candidates in the ledger ─────────────────────
        // `requested` is recorded first so it takes priority over `needs_review`
        // for any PR both searches return (first insertion wins the seq and the
        // bucket).  Drafts and self-authored PRs are recorded too, but skip the
        // CI read — resolving CI for a PR we'll never show is wasted budget.
        let mut b12_ci_targets: Vec<(String, u64)> = Vec::new();
        for (item, in_requested) in requested_items
            .iter()
            .map(|i| (i, true))
            .chain(needs_items.iter().map(|i| (i, false)))
        {
            let repo = repo_from_url(&item.repository_url);
            let first_sighting = !caches.candidates.contains_key(&(repo.clone(), item.number));
            let c = Candidate::upsert(
                &mut caches.candidates,
                &mut caches.next_seq,
                repo.clone(),
                item,
            );
            if in_requested {
                c.in_requested = true;
            } else {
                c.in_needs_review = true;
            }
            if !first_sighting {
                // Already queued for (or excluded from) a CI read this cycle.
                continue;
            }
            if is_filtered(item, me) {
                debug!(
                    url = %item.html_url,
                    author = item.user.as_ref().map(|u| u.login.as_str()).unwrap_or("(none)"),
                    draft = item.draft.unwrap_or(false),
                    "is_filtered: dropping"
                );
                continue;
            }
            b12_ci_targets.push((repo, item.number));
        }

        debug!(b12_candidates = b12_ci_targets.len(), "after is_filtered");

        // ── CI-filter buckets 1 & 2 concurrently ─────────────────────────────
        let b12_futures: Vec<_> = b12_ci_targets
            .into_iter()
            .map(|(repo, number)| {
                let client = client.clone();
                let head_sha_cache = Arc::clone(&head_sha_cache);
                let ci_state_cache = Arc::clone(&ci_state_cache);
                let endpoint_etags = Arc::clone(&endpoint_etags);
                let endpoint_body_cache = Arc::clone(&endpoint_body_cache);
                async move {
                    let (ci_state, failed, head_sha) = ci_state_cached(
                        &client,
                        &repo,
                        number,
                        &head_sha_cache,
                        &ci_state_cache,
                        &endpoint_etags,
                        &endpoint_body_cache,
                    )
                    .await;
                    ((repo, number), ci_state, failed, head_sha)
                }
            })
            .collect();

        // URLs already covered by buckets 1 & 2 — skip them in bucket 3.  A
        // candidate the CI filter dropped is deliberately *not* "covered": it
        // still gets a bucket-3 look, exactly as it did before the ledger.
        let mut known_urls: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut b12_survivors = 0usize;
        for (key, ci_state, failed, head_sha) in futures::future::join_all(b12_futures).await {
            if let Some(c) = caches.candidates.get_mut(&key) {
                c.ci_state = ci_state;
                c.actions_failed = failed;
                c.head_sha = head_sha;
                if !failed {
                    known_urls.insert(c.url.clone());
                    b12_survivors += 1;
                }
            }
        }

        debug!(b12_items = b12_survivors, "after CI filter");

        // Prune ci_state_cache: remove SHA entries that are no longer referenced
        // by any current PR head.  Runs after every cycle — the set is tiny.
        {
            let current_shas: std::collections::HashSet<String> =
                head_sha_cache.lock().unwrap().values().cloned().collect();
            ci_state_cache
                .lock()
                .unwrap()
                .retain(|sha, _| current_shas.contains(sha));
        }

        // ── Bucket 3: changes_req with new_activity ───────────────────────────
        // For each reviewed-by-me PR not already in b1/b2:
        //   - fetch our last review state via the reviews API
        //   - include only if state == CHANGES_REQUESTED and updated_at > submitted_at + 30s
        //
        // Every reviewed PR is recorded in the ledger first, including the ones
        // that don't qualify for a review lookup — the ledger is the record of
        // what the searches saw, not of what shipped.
        let mut b3_candidates: Vec<&SearchIssueItem> = Vec::new();
        for item in &reviewed_items {
            let repo = repo_from_url(&item.repository_url);
            Candidate::upsert(&mut caches.candidates, &mut caches.next_seq, repo, item);
            if !known_urls.contains(&item.html_url) && !is_filtered(item, me) {
                b3_candidates.push(item);
            }
        }

        // For each candidate, snapshot the cache state synchronously before spawning
        // futures.  The futures run concurrently via join_all and cannot hold &mut refs
        // to the caches, so we hand each future its own pre-computed Option.
        let b3_futures: Vec<_> = b3_candidates
            .into_iter()
            .map(|item| {
                let client = client.clone();
                let me = me.to_owned();
                let repo = repo_from_url(&item.repository_url);
                let key = (repo.clone(), item.number);

                let cached = review_from_cache(
                    &key,
                    item.updated_at.as_deref(),
                    &caches.last_seen_updated,
                    &caches.review_state_cache,
                );

                let head_sha_cache = Arc::clone(&head_sha_cache);
                let ci_state_cache = Arc::clone(&ci_state_cache);
                let endpoint_etags = Arc::clone(&endpoint_etags);
                let endpoint_body_cache = Arc::clone(&endpoint_body_cache);
                async move {
                    let (state, submitted_at, new_cache_entry) = match cached {
                        Some((s, sub)) => {
                            debug!(
                                repo = %repo,
                                number = item.number,
                                "bucket-3 review-state cache hit — skipping get_our_last_review"
                            );
                            (s, sub, None)
                        }
                        None => match get_our_last_review(
                            &client,
                            &repo,
                            item.number,
                            &me,
                            &endpoint_etags,
                            &endpoint_body_cache,
                        )
                        .await
                        {
                            Some((s, sub)) => {
                                let entry = Some((s.clone(), sub.clone()));
                                (s, sub, entry)
                            }
                            // No review of ours to speak of — nothing learned.
                            None => {
                                return B3Outcome {
                                    key,
                                    ..Default::default()
                                }
                            }
                        },
                    };

                    let my_review = Some((state.clone(), submitted_at.clone()));
                    let unresolved = B3Outcome {
                        key: key.clone(),
                        my_review: my_review.clone(),
                        ci: None,
                        new_cache_entry: new_cache_entry.clone(),
                    };

                    if state != "CHANGES_REQUESTED" {
                        return unresolved;
                    }

                    // Only read CI once the author has actually responded since
                    // our review (30s grace window to avoid self-triggering on
                    // our own submission).  Skipping the read is the point: a
                    // gate-failing candidate must cost zero GitHub requests.
                    if !has_new_activity(submitted_at.as_deref(), item.updated_at.as_deref()) {
                        return unresolved;
                    }

                    let (ci_state, failed, head_sha) = ci_state_cached(
                        &client,
                        &repo,
                        item.number,
                        &head_sha_cache,
                        &ci_state_cache,
                        &endpoint_etags,
                        &endpoint_body_cache,
                    )
                    .await;

                    B3Outcome {
                        key,
                        my_review,
                        ci: Some((ci_state, failed, head_sha)),
                        new_cache_entry,
                    }
                }
            })
            .collect();

        // Reduce: flush new review-state entries into the cache and fold what
        // each probe learned back into the ledger.
        for outcome in futures::future::join_all(b3_futures).await {
            if let Some(entry) = outcome.new_cache_entry {
                caches.review_state_cache.insert(outcome.key.clone(), entry);
            }
            let Some(c) = caches.candidates.get_mut(&outcome.key) else {
                continue;
            };
            if let Some(review) = outcome.my_review {
                c.my_review = Some(review);
            }
            if let Some((ci_state, failed, head_sha)) = outcome.ci {
                c.ci_state = ci_state;
                c.actions_failed = failed;
                c.head_sha = head_sha;
            }
        }

        // Record latest updated_at for every reviewed PR so future cycles can skip
        // unchanged ones (including PRs that fell into b1/b2 this cycle).
        for item in &reviewed_items {
            if let Some(updated_at) = &item.updated_at {
                let repo = repo_from_url(&item.repository_url);
                caches
                    .last_seen_updated
                    .insert((repo, item.number), updated_at.clone());
            }
        }

        self.apply_search_lag_grace(client, me, caches, carried)
            .await;

        // ── Render the ledger into the snapshot ───────────────────────────────
        // Deciding what ships is `classify`'s job; pruning expired suppression
        // entries is a side effect that rides along.  A PR whose current
        // head_sha exactly matches a live suppression entry is hidden — PRs with
        // an empty head_sha (unresolved) never match (is_suppressed() guards it).
        let items = render_with_suppression(caches, me, suppress);

        Ok(PrQueueSnapshot {
            generated_at: Some(Utc::now()),
            items,
            stale: false,
            error: None,
        })
    }

    /// Carry over PRs a targeted probe added that this poll's searches did not
    /// return — GitHub's search index lags the events the relay delivers, and
    /// without this a PR that appeared within ~3s of `pr.opened` would be
    /// yanked back out on the very next poll and flicker for a minute.
    ///
    /// Each carried PR is re-probed (1 GraphQL, **zero** search) so the poll's
    /// verdict stays authoritative: it survives only if it still qualifies.
    /// Capped so a pathological ledger can't turn one poll into a probe storm.
    ///
    /// Removals need no equivalent grace — a merged PR the index still lists is
    /// already dropped by `get_pr_head_sha` returning `Terminal`.
    async fn apply_search_lag_grace(
        &self,
        client: &GithubClient,
        me: &str,
        caches: &mut QueueCaches,
        carried: Vec<(String, u64, u64)>,
    ) {
        caches.last_grace_retained.clear();
        for (repo, number, first_seen_at) in carried {
            let key = (repo.clone(), number);
            match probe_and_upsert(client, me, caches, &key).await {
                ProbeResult::Open(_) => {}
                _ => {
                    debug!(
                        %repo, number,
                        "perri queue: recently-probed candidate is gone or unreadable — dropping"
                    );
                    continue;
                }
            }

            // Keep the *original* probe timestamp.  `upsert_from_probe` stamps
            // "now", which would re-arm the grace on every poll — a PR the
            // search index never returns would then be carried forever instead
            // of for two cycles.
            if let Some(c) = caches.candidates.get_mut(&key) {
                c.targeted_seen_at = Some(first_seen_at);
            }

            // The poll stays authoritative: the PR survives only if it still
            // belongs in a bucket.  A missing entry takes this branch too — no
            // direct index, no panic.
            if !qualifies(caches, &key, me) {
                remove_candidate(caches, &key);
                debug!(
                    %repo, number,
                    "perri queue: recently-probed candidate no longer qualifies — dropping"
                );
                continue;
            }

            debug!(
                %repo, number,
                "perri queue: search index has not caught up — carrying targeted candidate over"
            );
            caches.last_grace_retained.insert(key);
        }
    }

    fn build_client(&self) -> Result<GithubClient> {
        let hosts_path = self.config.github_token_path.as_deref();
        GithubClient::new(hosts_path)
    }
}

// ── Run-loop wake ─────────────────────────────────────────────────────────────

/// Why the run loop woke, and therefore what it should do.
#[derive(Debug)]
pub enum Wake {
    /// Re-derive the whole queue from the three searches.  `reason` is the
    /// wake source, for logs.  `deferred` is a relay reconnect's own events —
    /// empty for every other source.  A reconnect reconciles first: the fetch
    /// this variant drives runs before `deferred` is applied, on the very
    /// next wake, so a reconnect's batch is never silently dropped.
    Full {
        reason: &'static str,
        deferred: Vec<RelayEvent>,
    },
    /// Apply this batch of relay events to the ledger, touching only the PRs
    /// they name.  Never issues a search request.
    Targeted(Vec<RelayEvent>),
}

/// Which PRs a publish should kick off detail prefetch for.
pub enum PrefetchScope<'a> {
    /// The top 3, skipping any whose per-PR cache is already fresh.  What a
    /// full refresh has always done.
    TopThree,
    /// Only PRs that were *not* in the previous snapshot's top 3 and are in
    /// this one's.  A targeted CI-glyph change that doesn't reorder the top 3
    /// therefore prefetches nothing.
    NewlyTopThree(&'a [PrQueueItem]),
}

/// Block until the queue should act, then drain the signal channels and report
/// what to do.
///
/// Two properties here are load-bearing and must not be "simplified":
///
/// 1. **`Some(_) = rx.recv()`, never `_ = rx.recv()`.** `recv()` on a closed
///    channel returns `Poll::Ready(None)` forever; the `_` pattern matches it,
///    so the branch would fire on every poll and spin the loop into a tight
///    hammering of the GitHub search API.  `Some(_)` doesn't match `None`,
///    which makes `tokio::select!` *disable* the branch instead.
///    Regression test: `select_does_not_hot_fire_when_refresh_sender_dropped`.
///
/// 2. **The post-select drain of *all* channels.** One logical change (e.g.
///    `perri.clear_current_pr`) can touch the dirty sentinel *and* send on
///    `refresh_tx`; without the drain that is two wakes and two full fetch
///    cycles for one change.  Regression test:
///    `coalesces_dirty_refresh_and_approvals_signals_into_one_wake`.
///
/// Relay signals are the one wake source that does **not** always mean "full
/// refresh": a batch of events becomes [`Wake::Targeted`], and only a
/// (re)connect — which the relay cannot describe as an event, because it
/// buffers nothing for an absent subscriber — becomes a `Wake::Full`.
pub async fn wait_for_wake(
    dirty_rx: &mut mpsc::UnboundedReceiver<()>,
    refresh_rx: &mut mpsc::UnboundedReceiver<()>,
    approvals_rx: &mut mpsc::UnboundedReceiver<()>,
    relay_rx: &mut mpsc::UnboundedReceiver<QueueSignal>,
    interval_secs: u64,
    targeted_enabled: bool,
) -> Wake {
    /// Which branch won, before any draining.
    ///
    /// Same size trade-off as `QueueSignal` itself: one short-lived stack value
    /// per wake, immediately destructured.  Boxing to flatten the variants would
    /// cost an allocation on a path that runs a few times a minute.
    #[allow(clippy::large_enum_variant)]
    enum First {
        Full(&'static str),
        Relay(QueueSignal),
    }

    let first = tokio::select! {
        _ = tokio::time::sleep(std::time::Duration::from_secs(interval_secs)) => First::Full("interval"),
        Some(_) = dirty_rx.recv() => {
            debug!("perri queue dirty-file signal");
            First::Full("dirty")
        }
        Some(_) = refresh_rx.recv() => {
            debug!("perri queue direct-push refresh signal (MCP)");
            First::Full("refresh")
        }
        Some(_) = approvals_rx.recv() => {
            debug!("perri queue approvals-file signal — re-fetching with new suppression");
            First::Full("approvals")
        }
        Some(signal) = relay_rx.recv() => First::Relay(signal),
    };

    // The non-relay channels are always drained together — one logical change
    // can touch several of them (see property 2 above).
    let drain_non_relay =
        |dirty_rx: &mut mpsc::UnboundedReceiver<()>,
         refresh_rx: &mut mpsc::UnboundedReceiver<()>,
         approvals_rx: &mut mpsc::UnboundedReceiver<()>| {
            while dirty_rx.try_recv().is_ok() {}
            while refresh_rx.try_recv().is_ok() {}
            while approvals_rx.try_recv().is_ok() {}
        };

    let signal = match first {
        First::Full(reason) => {
            drain_non_relay(dirty_rx, refresh_rx, approvals_rx);
            // `relay_rx` is deliberately **not** drained here.  A relay event
            // describes a change GitHub's search index may not have picked up
            // yet, so discarding it because an unrelated dirty-file refresh
            // happened first would lose news the fetch cannot recover.  It costs
            // at most one extra loop iteration.
            return Wake::Full {
                reason,
                deferred: Vec::new(),
            };
        }
        First::Relay(signal) => signal,
    };

    // Drain the relay channel into one batch so a burst of events for the same
    // PR collapses into a single update and a single publish.
    let mut events: Vec<RelayEvent> = Vec::new();
    let mut reconnected = false;
    let mut absorb = |signal: QueueSignal| match signal {
        QueueSignal::Reconnected => reconnected = true,
        QueueSignal::Event(ev) => events.push(ev),
    };
    absorb(signal);
    while let Ok(signal) = relay_rx.try_recv() {
        absorb(signal);
    }

    if !targeted_enabled {
        // Kill switch: behave exactly as the queue did before the targeted
        // engine existed — every relay signal is a full refresh.
        drain_non_relay(dirty_rx, refresh_rx, approvals_rx);
        let reason = if reconnected {
            "relay_reconnect"
        } else {
            "relay_event"
        };
        debug!("perri queue relay signal — full refresh ({reason}, targeted path disabled)");
        return Wake::Full {
            reason,
            deferred: Vec::new(),
        };
    }

    if reconnected {
        // The relay buffered nothing while we were away, so reconcile first —
        // but keep the batch: these events may describe changes the reconciling
        // fetch's searches are still too stale to see.
        debug!(
            events = events.len(),
            "perri queue relay reconnect — reconciling, then applying the batch"
        );
        return Wake::Full {
            reason: "relay_reconnect",
            deferred: events,
        };
    }

    debug!(
        events = events.len(),
        "perri queue relay events — targeted update"
    );
    Wake::Targeted(events)
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Returns `true` if the GitHub login belongs to a known bot that should be
/// routed into the `"dependabot"` bucket rather than the human-review buckets.
///
/// This is the **single source of truth** for bot identity — the `review-prs`
/// skill delegates to the daemon queue's `is_bot` field and does not maintain
/// its own dependabot-discovery query.
pub fn is_bot(author: &str) -> bool {
    matches!(author, "dependabot" | "dependabot[bot]" | "carefeed-ci")
}

/// Returns `true` if the item should be excluded from all buckets:
/// draft PRs and self-authored PRs.
///
/// **Note:** bot-authored PRs are no longer excluded here — they flow through
/// to the `"dependabot"` bucket.  Use `is_bot()` to identify them.
fn is_filtered(item: &SearchIssueItem, me: &str) -> bool {
    if item.draft.unwrap_or(false) {
        return true;
    }
    let author = item.user.as_ref().map(|u| u.login.as_str()).unwrap_or("");
    author == me
}

/// Extract `{owner}/{repo}` from `https://api.github.com/repos/{owner}/{repo}`.
fn repo_from_url(repository_url: &str) -> String {
    repository_url
        .trim_start_matches("https://api.github.com/repos/")
        .to_owned()
}

/// Parse an ISO-8601 UTC timestamp to Unix epoch seconds.
/// Returns 0 on parse failure (safe for comparison purposes).
fn parse_epoch(ts: &str) -> u64 {
    // Strip trailing Z or +00:00 and parse with chrono.
    let ts = ts.trim_end_matches('Z').trim_end_matches("+00:00");
    chrono::NaiveDateTime::parse_from_str(ts, "%Y-%m-%dT%H:%M:%S")
        .map(|dt| dt.and_utc().timestamp() as u64)
        .unwrap_or(0)
}

/// The bucket-3 grace window: has the PR author responded since we last
/// reviewed?
///
/// `true` only when both timestamps are present and the PR was updated **more
/// than 30 seconds** after our review was submitted.  The window exists so
/// submitting a review — which itself bumps `updated_at` — doesn't immediately
/// re-surface the PR as "the author responded".
///
/// This is the single definition of that rule; nothing recomputes it inline.
pub fn has_new_activity(review_submitted_at: Option<&str>, pr_updated_at: Option<&str>) -> bool {
    match (review_submitted_at, pr_updated_at) {
        (Some(rev_ts), Some(pr_ts)) => {
            let review_epoch = parse_epoch(rev_ts);
            let pr_epoch = parse_epoch(pr_ts);
            pr_epoch.saturating_sub(review_epoch) > 30
        }
        _ => false,
    }
}

/// Returns the cached `(state, submitted_at)` for `key` if the PR's
/// `updated_at` matches the last-seen value (i.e. the PR hasn't changed since
/// the previous cycle).  Returns `None` if a fresh API call is needed.
fn review_from_cache(
    key: &(String, u64),
    updated_at: Option<&str>,
    last_seen_updated: &HashMap<(String, u64), String>,
    review_state_cache: &HashMap<(String, u64), (String, Option<String>)>,
) -> Option<(String, Option<String>)> {
    if last_seen_updated.get(key).map(|s| s.as_str()) == updated_at {
        review_state_cache.get(key).cloned()
    } else {
        None
    }
}

// ── GitHub API calls ──────────────────────────────────────────────────────────

/// Fetch the authenticated user's login.
async fn get_authenticated_user(client: &GithubClient) -> Result<String> {
    let resp = client
        .http
        .get(format!("{}/user", api_base()))
        .headers(base_headers(client))
        .send()
        .await
        .context("github /user request")?;
    resp.error_for_status_ref()
        .context("github /user non-2xx")?;
    let user: AuthenticatedUser = resp.json().await.context("parsing /user response")?;
    Ok(user.login)
}

/// Search GitHub issues/PRs.  Uses ETags to avoid re-processing on 304.
async fn search_issues(
    client: &GithubClient,
    query: &str,
    etags: &mut HashMap<String, String>,
    item_cache: &mut HashMap<String, Vec<SearchIssueItem>>,
) -> Result<Vec<SearchIssueItem>> {
    let url = format!(
        "{}/search/issues?q={}&per_page=100",
        api_base(),
        urlencoding::encode(query)
    );

    let mut headers = base_headers(client);
    if let Some(etag) = etags.get(query) {
        headers.insert(IF_NONE_MATCH, etag.parse().unwrap());
    }

    let resp = client
        .http
        .get(&url)
        .headers(headers)
        .send()
        .await
        .context("github search request")?;

    if let Some(etag) = resp.headers().get("etag").and_then(|v| v.to_str().ok()) {
        etags.insert(query.to_owned(), etag.to_owned());
    }

    if resp.status() == reqwest::StatusCode::NOT_MODIFIED {
        debug!("github search 304 for query: {query}");
        return Ok(item_cache.get(query).cloned().unwrap_or_default());
    }

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("github search -> {status}: {body}");
    }

    let search: SearchResponse = resp
        .json()
        .await
        .context("parsing github search response")?;
    let items = search.items;
    item_cache.insert(query.to_owned(), items.clone());
    Ok(items)
}

/// Returns the state and submitted_at of our most recent review on a PR.
/// Returns `None` if we have no reviews or the API call fails.
/// Uses ETag caching so repeated calls for an unchanged PR cost zero rate-limit budget.
async fn get_our_last_review(
    client: &GithubClient,
    repo: &str,
    number: u64,
    me: &str,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<(String, Option<String>)> {
    // `per_page=100` matters for parity, not just for long PRs: without it
    // GitHub returns the *oldest 30* reviews, so on a PR with more than 30 the
    // full fetch would pick a superseded review while the GraphQL probe
    // (`reviews(last: 100)`) picks the current one — the two paths would
    // disagree and this one would be wrong.
    let url = format!(
        "{}/repos/{repo}/pulls/{number}/reviews?per_page=100",
        api_base()
    );
    let body = etag_get(client, &url, etags, body_cache).await?;
    let reviews: Vec<ReviewItem> = serde_json::from_str(&body).ok()?;
    // Find our last review (last in the list wins).
    reviews
        .into_iter()
        .rfind(|r| r.user.as_ref().map(|u| u.login.as_str()) == Some(me))
        .map(|r| (r.state, r.submitted_at))
}

/// Fetch the check-runs for the PR head SHA and return:
///   - the display `CiState` (rollup over ALL runs, D1)
///   - whether a GitHub Actions run has `conclusion == "failure"` (the
///     filter bool — identical semantics to the old check-suites filter, D2)
///   - the resolved HEAD SHA (empty string on failure to resolve)
///
/// Results are cached by HEAD SHA so successive cycles skip the API call when
/// the PR hasn't received a new push.  Mutex guards are never held across
/// `.await` points.
pub async fn ci_state_cached(
    client: &GithubClient,
    repo: &str,
    number: u64,
    head_sha_cache: &Arc<Mutex<HashMap<(String, u64), String>>>,
    ci_state_cache: &Arc<Mutex<HashMap<String, (CiState, bool)>>>,
    endpoint_etags: &Arc<Mutex<HashMap<String, String>>>,
    endpoint_body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> (CiState, bool, String) {
    let sha = match get_pr_head_sha(client, repo, number, endpoint_etags, endpoint_body_cache).await
    {
        Some(GetPrHeadResult::Open(s)) => s,
        // Terminal (closed/merged): treat as a hard drop — same as Actions failure.
        Some(GetPrHeadResult::Terminal) => {
            debug!(%repo, number, "pr is closed/merged — dropping from queue");
            return (CiState::Unknown, true, String::new());
        }
        None => return (CiState::Unknown, false, String::new()),
    };

    let (state, failed) = ci_state_for_sha(
        client,
        repo,
        number,
        &sha,
        head_sha_cache,
        ci_state_cache,
        endpoint_etags,
        endpoint_body_cache,
    )
    .await;
    (state, failed, sha)
}

/// The half of [`ci_state_cached`] that runs once the HEAD SHA is already
/// known — from a relay event, a targeted probe, or the `/pulls/{n}` read
/// [`ci_state_cached`] itself performs.
///
/// Records `sha` in `head_sha_cache`, serves a cached terminal result if one
/// exists for that SHA, and otherwise calls `fetch_check_runs_state` exactly
/// once.  Issues **no** `/pulls/{number}` request — that is the caller's job.
///
/// Only terminal states (Success, Failure) are served from cache; Pending and
/// Unknown are transitional and re-fetch each cycle so completing checks are
/// detected.
#[allow(clippy::too_many_arguments)]
pub async fn ci_state_for_sha(
    client: &GithubClient,
    repo: &str,
    number: u64,
    sha: &str,
    head_sha_cache: &Arc<Mutex<HashMap<(String, u64), String>>>,
    ci_state_cache: &Arc<Mutex<HashMap<String, (CiState, bool)>>>,
    endpoint_etags: &Arc<Mutex<HashMap<String, String>>>,
    endpoint_body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> (CiState, bool) {
    // Record current head SHA (brief lock, no await).
    head_sha_cache
        .lock()
        .unwrap()
        .insert((repo.to_owned(), number), sha.to_owned());

    // Return cached result if the SHA hasn't changed since last cycle.
    {
        let lock = ci_state_cache.lock().unwrap();
        if let Some(&(state, failed)) = lock.get(sha) {
            if state != CiState::Pending && state != CiState::Unknown {
                debug!(%repo, number, "ci_state cache hit (sha unchanged)");
                return (state, failed);
            }
        }
    }

    // Cache miss — fetch check-runs. A failed read (`None`) establishes no
    // verdict, so it must not be cached: caching it would let a transient
    // transport hiccup calcify into a stale `Unknown` for every future cycle
    // that hits this SHA, instead of just retrying next time.
    match fetch_check_runs_state(client, repo, sha, endpoint_etags, endpoint_body_cache).await {
        Some(result) => {
            ci_state_cache
                .lock()
                .unwrap()
                .insert(sha.to_owned(), result);
            result
        }
        None => (CiState::Unknown, false),
    }
}

/// Fetch and parse check-runs for a known HEAD SHA.
///
/// Returns `None` when the read itself failed — a transport error, a non-2xx,
/// or an unparseable body — and `Some((display_state, actions_failure_filter))`
/// when it succeeded, which includes the "nothing configured on this SHA"
/// case (`Some((CiState::Unknown, false))`, from an empty `check_runs` array).
/// The distinction matters to callers: a failed read established no verdict
/// and must not be treated the same as a SHA GitHub has genuinely never run
/// anything on.
///
/// - `display_state` — rolled-up `CiState` over all check-runs (D1)
/// - `actions_failure_filter` — `true` iff a GitHub Actions run has
///   `conclusion == "failure"` (preserves the old check-suites filter
///   semantics, D2)
pub(crate) async fn fetch_check_runs_state(
    client: &GithubClient,
    repo: &str,
    sha: &str,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<(CiState, bool)> {
    let url = format!(
        "{}/repos/{repo}/commits/{sha}/check-runs?per_page=100",
        api_base()
    );
    let body = etag_get(client, &url, etags, body_cache).await?;

    let resp: CheckRunsResponse = serde_json::from_str(&body).ok()?;

    let display_state = CiState::rollup(
        resp.check_runs
            .iter()
            .map(|r| CiState::from_check(r.status.as_deref(), r.conclusion.as_deref())),
    );

    let actions_failure = resp.check_runs.iter().any(|r| {
        r.app.as_ref().and_then(|a| a.slug.as_deref()) == Some("github-actions")
            && CiState::from_check(r.status.as_deref(), r.conclusion.as_deref()) == CiState::Failure
    });

    Some((display_state, actions_failure))
}

/// Thin wrapper kept for backwards-compatibility with `tests/ci_failure_cache.rs`.
///
/// The test imports this function directly; rather than update the test we keep
/// this public function that delegates to `ci_state_cached` and returns only
/// the filter bool.  The `ci_state_cache` parameter mirrors the new internal
/// type — callers in the test create a fresh cache of the new type.
pub async fn ci_has_failure_cached(
    client: &GithubClient,
    repo: &str,
    number: u64,
    head_sha_cache: &Arc<Mutex<HashMap<(String, u64), String>>>,
    ci_state_cache: &Arc<Mutex<HashMap<String, (CiState, bool)>>>,
    endpoint_etags: &Arc<Mutex<HashMap<String, String>>>,
    endpoint_body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> bool {
    ci_state_cached(
        client,
        repo,
        number,
        head_sha_cache,
        ci_state_cache,
        endpoint_etags,
        endpoint_body_cache,
    )
    .await
    .1 // .1 is the actions-failure filter bool (index unchanged in the new 3-tuple)
}

/// Fetch the check-suites result for a known HEAD SHA.
///
/// Extracted from the old `ci_has_failure` body so it can be reused by both
/// the cached path and tests.  Uses ETag caching so a 304 on an unchanged SHA
/// consumes zero rate-limit budget.
pub async fn fetch_check_suites_failure(
    client: &GithubClient,
    repo: &str,
    sha: &str,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> bool {
    let url = format!("{}/repos/{repo}/commits/{sha}/check-suites", api_base());
    let body = match etag_get(client, &url, etags, body_cache).await {
        Some(b) => b,
        None => return false,
    };

    let suites: CheckSuitesResponse = match serde_json::from_str(&body) {
        Ok(s) => s,
        Err(_) => return false,
    };

    suites.check_suites.iter().any(|s| {
        s.app.as_ref().map(|a| a.name.as_str()) == Some("GitHub Actions")
            && s.conclusion.as_deref() == Some("failure")
    })
}

async fn get_pr_head_sha(
    client: &GithubClient,
    repo: &str,
    number: u64,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<GetPrHeadResult> {
    let url = format!("{}/repos/{repo}/pulls/{number}", api_base());
    let body = etag_get(client, &url, etags, body_cache).await?;
    let pr: PrDetail = serde_json::from_str(&body).ok()?;
    // Drop the item if the PR is already closed or merged — independent of
    // the GitHub search index, which can lag by a cycle after a merge.
    let is_terminal = pr.state.as_deref() == Some("closed")
        || pr.merged_at.as_deref().is_some_and(|s| !s.is_empty());
    if is_terminal {
        Some(GetPrHeadResult::Terminal)
    } else {
        Some(GetPrHeadResult::Open(pr.head.sha))
    }
}

/// Conditional GET helper.
///
/// Sends an `If-None-Match` header if we have a cached ETag for the URL.
/// On 304 Not Modified, returns the cached body (free: does not consume GitHub
/// rate-limit budget).  On 200+, stores the new ETag and body and returns the
/// body.  On network error or non-success non-304 status, returns `None`.
///
/// Bodies are stored as raw strings; callers deserialise with `serde_json::from_str`.
///
/// The Mutex guards are never held across `.await` points.
pub(crate) async fn etag_get(
    client: &GithubClient,
    url: &str,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<String> {
    // Brief lock — get existing ETag before the HTTP round-trip.
    let existing_etag = etags.lock().unwrap().get(url).cloned();

    let mut headers = base_headers(client);
    if let Some(ref etag) = existing_etag {
        if let Ok(val) = etag.parse() {
            headers.insert(IF_NONE_MATCH, val);
        }
    }

    let resp = client.http.get(url).headers(headers).send().await.ok()?;

    // Brief lock — update ETag from response.
    if let Some(etag) = resp.headers().get("etag").and_then(|v| v.to_str().ok()) {
        etags
            .lock()
            .unwrap()
            .insert(url.to_owned(), etag.to_owned());
    }

    if resp.status() == reqwest::StatusCode::NOT_MODIFIED {
        // 304 — serve from body cache (body is None only if we've never stored
        // a body for this URL, which can't happen after a prior 200 stored one).
        return body_cache.lock().unwrap().get(url).cloned();
    }

    if !resp.status().is_success() {
        return None;
    }

    let body = resp.text().await.ok()?;
    body_cache
        .lock()
        .unwrap()
        .insert(url.to_owned(), body.clone());
    Some(body)
}

/// Build the standard GitHub API request headers.
pub(crate) fn base_headers(client: &GithubClient) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(ACCEPT, "application/vnd.github+json".parse().unwrap());
    headers.insert("X-GitHub-Api-Version", "2022-11-28".parse().unwrap());
    headers.insert(
        AUTHORIZATION,
        format!("Bearer {}", client.token()).parse().unwrap(),
    );
    headers
}

// ── Queue file helpers ────────────────────────────────────────────────────────

/// Write `json` to `path` atomically via a temp-file + rename so a concurrent
/// reader never sees a partial write.
pub fn write_json_atomic(path: &Path, json: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json)?;
    std::fs::rename(&tmp, path)
}

/// Select the top-3 PRs in bucket-priority order:
/// `requested` → `needs_review` → `changes_req` → `dependabot`; preserve within-bucket order.
///
/// Dependabot PRs sit last — they rarely require reading the diff, so prefetching
/// them over a human-review PR wastes the limited prefetch budget.
pub fn top_three_items(items: &[PrQueueItem]) -> Vec<&PrQueueItem> {
    let bucket_order = |b: &str| match b {
        "requested" => 0usize,
        "needs_review" => 1,
        "changes_req" => 2,
        "dependabot" => 3,
        _ => 4,
    };
    let mut sorted: Vec<&PrQueueItem> = items.iter().collect();
    sorted.sort_by_key(|i| bucket_order(&i.bucket));
    sorted.into_iter().take(3).collect()
}

/// The PRs a publish should prefetch detail for.
///
/// Pure, so the "a glyph change that doesn't reorder the top 3 prefetches
/// nothing" rule is testable without observing spawned tasks.
pub fn prefetch_targets<'a>(
    scope: &PrefetchScope<'_>,
    items: &'a [PrQueueItem],
) -> Vec<&'a PrQueueItem> {
    let next = top_three_items(items);
    match scope {
        PrefetchScope::TopThree => next,
        PrefetchScope::NewlyTopThree(prev) => {
            let was: std::collections::HashSet<(&str, u64)> = top_three_items(prev)
                .into_iter()
                .map(|i| (i.repo.as_str(), i.number))
                .collect();
            next.into_iter()
                .filter(|i| !was.contains(&(i.repo.as_str(), i.number)))
                .collect()
        }
    }
}

/// Returns `true` iff the per-PR cache file for `(repo, number)` exists, its
/// `head_sha` matches `sha`, and it was written within the last 10 minutes.
fn cache_is_fresh(state_dir: &Path, repo: &str, number: u64, sha: &str) -> bool {
    if sha.is_empty() {
        return false;
    }
    let safe = repo.replace('/', "-");
    let path = state_dir
        .join("pr-cache")
        .join(format!("{safe}-{number}.json"));

    // Check mtime first (fast).
    let mtime_ok = std::fs::metadata(&path)
        .and_then(|m| m.modified())
        .map(|mt| {
            SystemTime::now()
                .duration_since(mt)
                .map(|d| d.as_secs() < 600)
                .unwrap_or(false)
        })
        .unwrap_or(false);

    if !mtime_ok {
        return false;
    }

    // Decode the cached `head_sha` field and compare.
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(_) => return false,
    };
    // We only need the head_sha field; use a lightweight partial decode.
    #[derive(Deserialize)]
    struct HeadShaOnly {
        #[serde(default)]
        head_sha: String,
    }
    let cached: HeadShaOnly = match serde_json::from_slice(&bytes) {
        Ok(v) => v,
        Err(_) => return false,
    };
    cached.head_sha == sha
}

// ── URL encoding ──────────────────────────────────────────────────────────────

mod urlencoding {
    pub fn encode(s: &str) -> String {
        url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Regression guard for the refresh-channel hot loop.
    ///
    /// The run loop waits on a `tokio::select!` over four branches:
    /// `sleep(interval)`, `dirty_rx.recv()`, `refresh_rx.recv()`, and
    /// `approvals_rx.recv()`.
    /// When the corresponding sender is dropped, `recv()` returns
    /// `Poll::Ready(None)` on every poll forever.  If the select branch
    /// uses `_ = recv() => ...`, it fires on every iteration, producing
    /// a tight loop that hammers the GitHub search API (~120ms cadence,
    /// 24+ search calls/sec, exhausting the 30/min search bucket in
    /// seconds and triggering 403s repeatedly).
    ///
    /// The fix is `Some(_) = recv() => ...` — the pattern doesn't match
    /// `None`, which causes tokio::select! to *disable* that branch when
    /// the channel is closed, letting the sleep branch win normally.
    ///
    /// This test exercises the exact select! shape used in `run()` to
    /// catch any future regression that swaps the pattern back — including
    /// the newly-added `approvals_rx` branch.
    #[tokio::test]
    async fn select_does_not_hot_fire_when_refresh_sender_dropped() {
        use std::time::Duration;
        use tokio::sync::mpsc;

        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();
        let (refresh_tx, mut refresh_rx) = mpsc::unbounded_channel::<()>();
        let (approvals_tx, mut approvals_rx) = mpsc::unbounded_channel::<()>();

        // Simulate the bug condition: all senders except dirty_tx are dropped.
        // With the `_ = recv()` form the closed channel's None return would win
        // every iteration; with `Some(_) = recv()` the branch is disabled
        // and the sleep wins.
        drop(refresh_tx);
        drop(approvals_tx);

        // Short interval so the test stays fast — the assertion is that
        // the select waits the full interval, not that any particular
        // duration is held.
        let interval = Duration::from_millis(120);

        let start = std::time::Instant::now();
        tokio::select! {
            _ = tokio::time::sleep(interval) => {}
            Some(_) = dirty_rx.recv() => {
                panic!("dirty branch fired with no sender activity");
            }
            Some(_) = refresh_rx.recv() => {
                panic!("refresh branch fired when sender was dropped (the regression)");
            }
            Some(_) = approvals_rx.recv() => {
                panic!("approvals branch fired when sender was dropped (the regression)");
            }
        }
        let elapsed = start.elapsed();
        assert!(
            elapsed >= Duration::from_millis(100),
            "select! returned early ({elapsed:?} < ~100ms) — a closed \
             channel branch is firing on every poll"
        );

        // Keep dirty_tx alive past the select so it's not the closed
        // channel that wins.
        let _ = dirty_tx;
    }

    /// Regression guard for the double-wake coalescing fix (D6).
    ///
    /// `perri.clear_current_pr` touches `queue.dirty` *and* signals
    /// `refresh_tx` for the same logical change. Without the post-select
    /// drain, that produces two pending wakes and two fetch cycles (and two
    /// GitHub search calls) for one change. This exercises the exact
    /// `select!` + drain shape used in `run()`, without touching the
    /// network: queue all three signal channels, confirm the first select
    /// cycle fires immediately, drain the leftovers, then assert a second
    /// select waits the full interval — proving no extra cycle followed.
    #[tokio::test]
    async fn coalesces_dirty_refresh_and_approvals_signals_into_one_wake() {
        use std::time::Duration;
        use tokio::sync::mpsc;

        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();
        let (refresh_tx, mut refresh_rx) = mpsc::unbounded_channel::<()>();
        let (approvals_tx, mut approvals_rx) = mpsc::unbounded_channel::<()>();

        dirty_tx.send(()).unwrap();
        refresh_tx.send(()).unwrap();
        approvals_tx.send(()).unwrap();

        let interval = Duration::from_millis(200);

        tokio::select! {
            _ = tokio::time::sleep(interval) => panic!("select should fire immediately with signals pending"),
            Some(_) = dirty_rx.recv() => {}
            Some(_) = refresh_rx.recv() => {}
            Some(_) = approvals_rx.recv() => {}
        }
        while dirty_rx.try_recv().is_ok() {}
        while refresh_rx.try_recv().is_ok() {}
        while approvals_rx.try_recv().is_ok() {}

        let start = std::time::Instant::now();
        tokio::select! {
            _ = tokio::time::sleep(interval) => {}
            Some(_) = dirty_rx.recv() => panic!("dirty branch fired after drain — coalescing failed"),
            Some(_) = refresh_rx.recv() => panic!("refresh branch fired after drain — coalescing failed"),
            Some(_) = approvals_rx.recv() => panic!("approvals branch fired after drain — coalescing failed"),
        }
        assert!(
            start.elapsed() >= Duration::from_millis(150),
            "select returned early — a leftover signal was not drained"
        );

        drop(dirty_tx);
        drop(refresh_tx);
        drop(approvals_tx);
    }

    fn make_item(login: &str, draft: bool, updated_at: Option<&str>) -> SearchIssueItem {
        SearchIssueItem {
            number: 1,
            title: "Test PR".to_owned(),
            html_url: "https://github.com/Carefeed/care/pull/1".to_owned(),
            repository_url: "https://api.github.com/repos/Carefeed/care".to_owned(),
            user: Some(GhUser {
                login: login.to_owned(),
            }),
            draft: Some(draft),
            updated_at: updated_at.map(|s| s.to_owned()),
        }
    }

    // ── review_from_cache ──────────────────────────────────────────────────────

    #[test]
    fn review_cache_hit_when_updated_at_unchanged() {
        let key = ("Carefeed/care".to_owned(), 42u64);
        let ts = "2025-01-01T00:00:00Z".to_owned();
        let mut last_seen: HashMap<(String, u64), String> = HashMap::new();
        last_seen.insert(key.clone(), ts.clone());
        let mut rev_cache: HashMap<(String, u64), (String, Option<String>)> = HashMap::new();
        rev_cache.insert(
            key.clone(),
            ("CHANGES_REQUESTED".to_owned(), Some(ts.clone())),
        );

        let result = review_from_cache(&key, Some(&ts), &last_seen, &rev_cache);
        assert!(result.is_some());
        assert_eq!(result.unwrap().0, "CHANGES_REQUESTED");
    }

    #[test]
    fn review_cache_miss_when_updated_at_changed() {
        let key = ("Carefeed/care".to_owned(), 42u64);
        let old_ts = "2025-01-01T00:00:00Z".to_owned();
        let new_ts = "2025-01-02T00:00:00Z".to_owned();
        let mut last_seen: HashMap<(String, u64), String> = HashMap::new();
        last_seen.insert(key.clone(), old_ts.clone());
        let mut rev_cache: HashMap<(String, u64), (String, Option<String>)> = HashMap::new();
        rev_cache.insert(key.clone(), ("CHANGES_REQUESTED".to_owned(), Some(old_ts)));

        // Different updated_at → cache miss, API call needed.
        assert!(review_from_cache(&key, Some(&new_ts), &last_seen, &rev_cache).is_none());
    }

    #[test]
    fn review_cache_miss_for_unseen_pr() {
        let key = ("Carefeed/care".to_owned(), 42u64);
        let ts = "2025-01-01T00:00:00Z";
        let last_seen: HashMap<(String, u64), String> = HashMap::new();
        let rev_cache: HashMap<(String, u64), (String, Option<String>)> = HashMap::new();

        // Never seen before → always a miss.
        assert!(review_from_cache(&key, Some(ts), &last_seen, &rev_cache).is_none());
    }

    // ── bucket-3 inclusion logic ───────────────────────────────────────────────
    //
    // Verifies that the 30-second grace window used to determine new_activity is
    // applied correctly.  PRs updated within 30s of our review are NOT included;
    // PRs updated more than 30s after our review ARE included (state still
    // checked separately by the caller).

    #[test]
    fn new_activity_gate_at_30s_boundary() {
        let review_ts = "2025-01-01T00:00:00Z";
        let review_epoch = parse_epoch(review_ts);

        // Exactly 30s after — still within grace window, not new activity.
        let same = parse_epoch("2025-01-01T00:00:30Z");
        assert!(same.saturating_sub(review_epoch) <= 30);

        // 31s after — beyond grace window, counts as new activity.
        let after = parse_epoch("2025-01-01T00:00:31Z");
        assert!(after.saturating_sub(review_epoch) > 30);
    }

    // ── is_bot ────────────────────────────────────────────────────────────────

    #[test]
    fn is_bot_recognises_all_bot_logins() {
        for login in &["dependabot", "dependabot[bot]", "carefeed-ci"] {
            assert!(
                is_bot(login),
                "expected '{login}' to be recognised as a bot"
            );
        }
    }

    #[test]
    fn is_bot_returns_false_for_humans() {
        for login in &["alice", "hammer", "app/dependabot", "dependabot-bot"] {
            assert!(!is_bot(login), "expected '{login}' not to be a bot");
        }
    }

    // ── is_filtered ───────────────────────────────────────────────────────────

    #[test]
    fn is_filtered_excludes_drafts() {
        assert!(is_filtered(&make_item("alice", true, None), "hammer"));
    }

    #[test]
    fn is_filtered_excludes_self_authored_prs() {
        assert!(is_filtered(&make_item("hammer", false, None), "hammer"));
    }

    #[test]
    fn is_filtered_does_not_exclude_bots() {
        // Bots are no longer dropped by is_filtered — they flow through to the
        // "dependabot" bucket.  is_bot() is the single source of truth.
        for bot in &["dependabot", "dependabot[bot]", "carefeed-ci"] {
            assert!(
                !is_filtered(&make_item(bot, false, None), "hammer"),
                "bot '{bot}' should pass is_filtered (routed to dependabot bucket instead)"
            );
        }
    }

    #[test]
    fn is_filtered_passes_normal_prs() {
        assert!(!is_filtered(&make_item("alice", false, None), "hammer"));
    }

    // ── Suppression integration tests ─────────────────────────────────────────
    //
    // These tests verify the end-to-end suppression filter inside `fetch()`.
    // They are inline (rather than in `tests/`) because `fetch()` is a private
    // method and this gives direct access without exposing it in the public API.
    //
    // Pattern: mock GitHub search + PR detail + check-runs, call `fetch()` with
    // a pre-populated `SuppressStore`, and assert presence/absence in the snapshot.

    /// Build a minimal `PerriQueueNativeSource` pointed at a temp hosts.yml.
    fn make_source() -> (PerriQueueNativeSource, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let hosts_path = dir.path().join("hosts.yml");
        std::fs::write(
            &hosts_path,
            "github.com:\n  oauth_token: test-token\n  user: tester\n  git_protocol: https\n",
        )
        .unwrap();
        std::env::remove_var("GITHUB_TOKEN");
        let cfg = crate::config::Config {
            github_token_path: Some(hosts_path),
            // Point perri_state at the tempdir so suppress-state files land there.
            perri_state: Some(dir.path().to_path_buf()),
            ..Default::default()
        };
        (PerriQueueNativeSource { config: cfg }, dir)
    }

    /// Call `fetch()` with the given suppress store, returning the snapshot.
    async fn run_fetch(
        source: &PerriQueueNativeSource,
        suppress: Arc<Mutex<SuppressStore>>,
    ) -> PrQueueSnapshot {
        let client = source.build_client().unwrap();
        let mut caches = QueueCaches::default();
        source
            .fetch(&client, "tester", &mut caches, &suppress)
            .await
            .expect("fetch() should succeed")
    }

    /// Register the three GitHub mock endpoints needed to return PR #42 in
    /// `review:required` with head SHA `head_sha` and passing CI.
    async fn mount_pr_mocks(server: &wiremock::MockServer, head_sha: &str) {
        use serde_json::json;
        use wiremock::matchers::{method, path, path_regex, query_param};
        use wiremock::{Mock, ResponseTemplate};

        // /user — authenticated user
        Mock::given(method("GET"))
            .and(path("/user"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "login": "tester"
            })))
            .mount(server)
            .await;

        // review-requested — empty (PR is only in needs_review)
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr review-requested:@me org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(server)
            .await;

        // review:required — returns PR #42
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr review:required org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "items": [{
                    "number": 42,
                    "title": "Add feature X",
                    "html_url": "https://github.com/Carefeed/admin-portal/pull/42",
                    "repository_url": "https://api.github.com/repos/Carefeed/admin-portal",
                    "user": { "login": "alice" },
                    "draft": false,
                    "updated_at": "2026-06-07T12:00:00Z"
                }]
            })))
            .mount(server)
            .await;

        // reviewed-by — empty (no bucket-3 PRs)
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr reviewed-by:@me org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(server)
            .await;

        // PR detail — head SHA
        let head_sha = head_sha.to_owned();
        Mock::given(method("GET"))
            .and(path("/repos/Carefeed/admin-portal/pulls/42"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "head": { "sha": head_sha }
            })))
            .mount(server)
            .await;

        // Check-runs — passing CI
        Mock::given(method("GET"))
            .and(path_regex(r".*/commits/.*/check-runs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "check_runs": [{
                    "name": "build",
                    "status": "completed",
                    "conclusion": "success",
                    "id": 1,
                    "app": { "slug": "github-actions" },
                    "output": {}
                }]
            })))
            .mount(server)
            .await;
    }

    /// A suppressed PR (matching sha) is absent from the snapshot.
    #[tokio::test]
    async fn fetch_excludes_suppressed_pr() {
        use wiremock::MockServer;

        let server = MockServer::start().await;
        API_BASE_OVERRIDE.with(|c| *c.borrow_mut() = Some(server.uri()));

        let head_sha = "abc123";
        mount_pr_mocks(&server, head_sha).await;

        let (source, _dir) = make_source();
        let ttl = std::time::Duration::from_secs(900);
        let state_path = source.config.perri_state_dir().join("approvals-state.json");
        let mut store = SuppressStore::new(state_path, ttl);
        store.record("Carefeed/admin-portal", 42, head_sha, unix_now_secs());
        let suppress = Arc::new(Mutex::new(store));

        let snap = run_fetch(&source, suppress).await;
        assert!(
            snap.items.is_empty(),
            "suppressed PR should not appear in snapshot, got: {:?}",
            snap.items.iter().map(|i| i.number).collect::<Vec<_>>()
        );
    }

    /// When the head SHA differs from the recorded entry, the PR reappears.
    #[tokio::test]
    async fn fetch_includes_pr_when_sha_differs() {
        use wiremock::MockServer;

        let server = MockServer::start().await;
        API_BASE_OVERRIDE.with(|c| *c.borrow_mut() = Some(server.uri()));

        // GitHub returns sha-new but we recorded sha-old → not suppressed.
        mount_pr_mocks(&server, "sha-new").await;

        let (source, _dir) = make_source();
        let ttl = std::time::Duration::from_secs(900);
        let state_path = source.config.perri_state_dir().join("approvals-state.json");
        let mut store = SuppressStore::new(state_path, ttl);
        store.record("Carefeed/admin-portal", 42, "sha-old", unix_now_secs());
        let suppress = Arc::new(Mutex::new(store));

        let snap = run_fetch(&source, suppress).await;
        assert_eq!(
            snap.items.len(),
            1,
            "PR with different sha should appear in snapshot"
        );
        assert_eq!(snap.items[0].number, 42);
    }

    /// A PR not in the suppression store always appears normally.
    #[tokio::test]
    async fn fetch_includes_unsuppressed_pr() {
        use wiremock::MockServer;

        let server = MockServer::start().await;
        API_BASE_OVERRIDE.with(|c| *c.borrow_mut() = Some(server.uri()));

        mount_pr_mocks(&server, "sha-abc").await;

        let (source, _dir) = make_source();
        let ttl = std::time::Duration::from_secs(900);
        let state_path = source.config.perri_state_dir().join("approvals-state.json");
        let store = SuppressStore::new(state_path, ttl);
        let suppress = Arc::new(Mutex::new(store));

        let snap = run_fetch(&source, suppress).await;
        assert_eq!(
            snap.items.len(),
            1,
            "unsuppressed PR should appear in snapshot"
        );
        assert_eq!(snap.items[0].number, 42);
        assert_eq!(snap.items[0].head_sha, "sha-abc");
    }

    /// Empty head_sha on a queue item is never suppressed, even if an entry
    /// exists in the store — guards against accidentally hiding PRs whose SHA
    /// couldn't be resolved.
    #[test]
    fn suppression_never_fires_on_empty_head_sha() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = SuppressStore::new(
            dir.path().join("state.json"),
            std::time::Duration::from_secs(900),
        );
        let now = unix_now_secs();
        // Record an entry with an empty sha (shouldn't happen in practice but
        // must be safe).
        store.record("acme/repo", 99, "", now);
        // Checking with empty sha should never be suppressed.
        assert!(
            !store.is_suppressed("acme/repo", 99, "", now + 1),
            "empty head_sha must never be suppressed"
        );
    }

    // ── Dependabot grouping integration tests ─────────────────────────────────

    /// Mount mocks for a dependabot-authored PR in the needs_review bucket.
    async fn mount_dependabot_pr_mocks(server: &wiremock::MockServer, head_sha: &str) {
        use serde_json::json;
        use wiremock::matchers::{method, path, path_regex, query_param};
        use wiremock::{Mock, ResponseTemplate};

        Mock::given(method("GET"))
            .and(path("/user"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"login": "tester"})))
            .mount(server)
            .await;

        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr review-requested:@me org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(server)
            .await;

        let head_sha_owned = head_sha.to_owned();
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr review:required org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "items": [{
                    "number": 100,
                    "title": "chore: bump serde from 1.0.195 to 1.0.196",
                    "html_url": "https://github.com/Carefeed/admin-portal/pull/100",
                    "repository_url": "https://api.github.com/repos/Carefeed/admin-portal",
                    "user": { "login": "dependabot[bot]" },
                    "draft": false,
                    "updated_at": "2026-06-07T12:00:00Z"
                }]
            })))
            .mount(server)
            .await;

        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr reviewed-by:@me org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(server)
            .await;

        Mock::given(method("GET"))
            .and(path("/repos/Carefeed/admin-portal/pulls/100"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "head": { "sha": head_sha_owned },
                "state": "open",
                "merged_at": null
            })))
            .mount(server)
            .await;

        Mock::given(method("GET"))
            .and(path_regex(r".*/commits/.*/check-runs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "check_runs": [{
                    "name": "build", "status": "completed", "conclusion": "success",
                    "id": 1, "app": { "slug": "github-actions" }, "output": {}
                }]
            })))
            .mount(server)
            .await;
    }

    /// A dependabot-authored PR appears in the snapshot with bucket == "dependabot"
    /// and is_bot == true instead of being silently dropped.
    #[tokio::test]
    async fn fetch_routes_dependabot_pr_to_dependabot_bucket() {
        use wiremock::MockServer;

        let server = MockServer::start().await;
        API_BASE_OVERRIDE.with(|c| *c.borrow_mut() = Some(server.uri()));

        mount_dependabot_pr_mocks(&server, "bot-sha-1").await;

        let (source, _dir) = make_source();
        let suppress = Arc::new(Mutex::new(SuppressStore::new(
            source.config.perri_state_dir().join("approvals-state.json"),
            std::time::Duration::from_secs(900),
        )));

        let snap = run_fetch(&source, suppress).await;

        assert_eq!(
            snap.items.len(),
            1,
            "dependabot PR should appear in snapshot"
        );
        let item = &snap.items[0];
        assert_eq!(item.number, 100);
        assert_eq!(
            item.bucket, "dependabot",
            "dependabot PR must land in 'dependabot' bucket"
        );
        assert!(item.is_bot, "is_bot must be true for a dependabot PR");
        assert_eq!(item.head_sha, "bot-sha-1");
    }

    // ── Merged/closed PR exclusion integration tests ──────────────────────────

    /// Mount mocks for a PR that the search index still returns as open but
    /// whose PR detail shows it has been merged.
    async fn mount_merged_pr_mocks(server: &wiremock::MockServer) {
        use serde_json::json;
        use wiremock::matchers::{method, path, query_param};
        use wiremock::{Mock, ResponseTemplate};

        Mock::given(method("GET"))
            .and(path("/user"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"login": "tester"})))
            .mount(server)
            .await;

        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr review-requested:@me org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(server)
            .await;

        // Search index still returns PR #55 as open (lag)
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr review:required org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "items": [{
                    "number": 55,
                    "title": "fix: something",
                    "html_url": "https://github.com/Carefeed/admin-portal/pull/55",
                    "repository_url": "https://api.github.com/repos/Carefeed/admin-portal",
                    "user": { "login": "alice" },
                    "draft": false,
                    "updated_at": "2026-06-07T12:00:00Z"
                }]
            })))
            .mount(server)
            .await;

        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr reviewed-by:@me org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(server)
            .await;

        // PR detail shows merged_at is set → terminal
        Mock::given(method("GET"))
            .and(path("/repos/Carefeed/admin-portal/pulls/55"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "head": { "sha": "merged-sha" },
                "state": "closed",
                "merged_at": "2026-06-07T11:58:00Z"
            })))
            .mount(server)
            .await;
    }

    /// A PR that has been merged is dropped from the snapshot even if the
    /// search index still returns it as open.
    #[tokio::test]
    async fn fetch_drops_merged_pr_despite_search_index_lag() {
        use wiremock::MockServer;

        let server = MockServer::start().await;
        API_BASE_OVERRIDE.with(|c| *c.borrow_mut() = Some(server.uri()));

        mount_merged_pr_mocks(&server).await;

        let (source, _dir) = make_source();
        let suppress = Arc::new(Mutex::new(SuppressStore::new(
            source.config.perri_state_dir().join("approvals-state.json"),
            std::time::Duration::from_secs(900),
        )));

        let snap = run_fetch(&source, suppress).await;
        assert!(
            snap.items.is_empty(),
            "merged PR must not appear in snapshot even if search index lags; \
             got: {:?}",
            snap.items.iter().map(|i| i.number).collect::<Vec<_>>()
        );
    }

    /// A PR whose detail shows state == "closed" but merged_at is null (closed
    /// without merge) is also dropped.
    #[tokio::test]
    async fn fetch_drops_closed_unmerged_pr() {
        use serde_json::json;
        use wiremock::matchers::{method, path, query_param};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let server = MockServer::start().await;
        API_BASE_OVERRIDE.with(|c| *c.borrow_mut() = Some(server.uri()));

        Mock::given(method("GET"))
            .and(path("/user"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"login": "tester"})))
            .mount(&server)
            .await;

        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr review-requested:@me org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(&server)
            .await;

        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr review:required org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "items": [{
                    "number": 66,
                    "title": "wip: abandoned",
                    "html_url": "https://github.com/Carefeed/admin-portal/pull/66",
                    "repository_url": "https://api.github.com/repos/Carefeed/admin-portal",
                    "user": { "login": "bob" },
                    "draft": false,
                    "updated_at": "2026-06-07T12:00:00Z"
                }]
            })))
            .mount(&server)
            .await;

        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param(
                "q",
                "is:open is:pr reviewed-by:@me org:Carefeed archived:false",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(&server)
            .await;

        // Closed (not merged) — state == "closed", merged_at == null
        Mock::given(method("GET"))
            .and(path("/repos/Carefeed/admin-portal/pulls/66"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "head": { "sha": "closed-sha" },
                "state": "closed",
                "merged_at": null
            })))
            .mount(&server)
            .await;

        let (source, _dir) = make_source();
        let suppress = Arc::new(Mutex::new(SuppressStore::new(
            source.config.perri_state_dir().join("approvals-state.json"),
            std::time::Duration::from_secs(900),
        )));

        let snap = run_fetch(&source, suppress).await;
        assert!(
            snap.items.is_empty(),
            "closed (unmerged) PR must not appear in snapshot; \
             got: {:?}",
            snap.items.iter().map(|i| i.number).collect::<Vec<_>>()
        );
    }

    // ── run_full_refresh: a failed poll must not discard the audit set ────────

    /// `run_full_refresh`'s `Err` arm used to publish a stale snapshot and
    /// return, dropping whatever `touched_since_poll` it had just taken
    /// ownership of on the floor. A poll that fails — a transient GitHub
    /// outage, a rate limit — must not silently erase the record of which PRs a
    /// targeted update touched since the last successful poll: losing that set
    /// means the *next* successful poll's divergence audit runs against an
    /// empty audit set and silently stops checking the very PRs it exists to
    /// check.
    #[tokio::test]
    async fn failed_poll_preserves_the_audit_set_instead_of_dropping_it() {
        use wiremock::MockServer;

        // No mocks mounted at all — the first search call gets an unmatched
        // 404, so `fetch()` returns `Err(...)`.
        let server = MockServer::start().await;
        API_BASE_OVERRIDE.with(|c| *c.borrow_mut() = Some(server.uri()));

        let (source, dir) = make_source();
        let client = source.build_client().unwrap();
        let mut caches = QueueCaches::default();
        let suppress = Arc::new(Mutex::new(SuppressStore::new(
            dir.path().join("approvals-state.json"),
            std::time::Duration::from_secs(900),
        )));

        let mut tstate = TargetedState::default();
        let seeded_key = ("Carefeed/admin-portal".to_owned(), 42u64);
        tstate.touched_since_poll.insert(seeded_key.clone());

        // A healthy "previous" snapshot: not stale, no error.
        let (tx, _rx) = watch::channel(Some(PrQueueSnapshot::default()));

        // `consume_approvals_file` early-returns 0 when the path is absent.
        let approvals_path = dir.path().join("does-not-exist-approvals.jsonl");

        source
            .run_full_refresh(
                &client,
                "tester",
                &mut caches,
                &suppress,
                &mut tstate,
                &tx,
                &approvals_path,
                "test",
            )
            .await;

        assert!(
            tstate.touched_since_poll.contains(&seeded_key),
            "a failed poll must not discard the audit set it took ownership of; \
             got {:?}",
            tstate.touched_since_poll
        );

        let published = tx
            .borrow()
            .clone()
            .expect("a snapshot must still be published");
        assert!(
            published.stale,
            "a failed poll must mark the republished snapshot stale"
        );
    }
}
