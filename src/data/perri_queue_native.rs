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

use std::collections::HashMap;
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
        perri_suppress::{SuppressStore, unix_now_secs},
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

fn api_base() -> String {
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
struct SearchIssueItem {
    number: u64,
    title: String,
    html_url: String,
    repository_url: String,
    user: Option<GhUser>,
    draft: Option<bool>,
    updated_at: Option<String>,
}

#[derive(Deserialize, Clone)]
struct GhUser {
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

// ── Source ────────────────────────────────────────────────────────────────────

pub struct PerriQueueNativeSource {
    config: Config,
}

impl PerriQueueNativeSource {
    /// Spawn the data source.
    ///
    /// Returns `(snapshot_rx, refresh_tx)`.
    ///
    /// Phase 4: `refresh_tx` allows MCP tools to request an immediate queue
    /// re-fetch without touching the dirty-file sentinel.
    pub fn spawn(
        config: Config,
    ) -> (
        watch::Receiver<Option<PrQueueSnapshot>>,
        mpsc::UnboundedSender<()>,
    ) {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();
        let (refresh_tx, mut refresh_rx) = mpsc::unbounded_channel::<()>();
        let (approvals_tx, mut approvals_rx) = mpsc::unbounded_channel::<()>();

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
                .run(tx, &mut dirty_rx, &mut refresh_rx, &mut approvals_rx, suppress, interval_secs)
                .await;
        });

        (rx, refresh_tx)
    }

    async fn run(
        &self,
        tx: watch::Sender<Option<PrQueueSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
        refresh_rx: &mut mpsc::UnboundedReceiver<()>,
        approvals_rx: &mut mpsc::UnboundedReceiver<()>,
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

        // ETag cache per search query string.
        let mut etags: HashMap<String, String> = HashMap::new();
        // Item cache per search query (for 304 reuse).
        let mut item_cache: HashMap<String, Vec<SearchIssueItem>> = HashMap::new();
        // updated_at seen on last fetch per (repo, number) — used to skip review re-fetches.
        let mut last_seen_updated: HashMap<(String, u64), String> = HashMap::new();
        // Cached last review state per (repo, number).
        let mut review_state_cache: HashMap<(String, u64), (String, Option<String>)> =
            HashMap::new();
        // Authenticated user login — fetched once and reused.
        let mut me: Option<String> = None;
        // CI caches — persist across loop iterations so successive cycles skip
        // the check-runs call when the HEAD SHA hasn't changed.
        let head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>> =
            Arc::new(Mutex::new(HashMap::new()));
        // Maps HEAD SHA → (display CiState, Actions-failure filter bool).
        let ci_state_cache: Arc<Mutex<HashMap<String, (CiState, bool)>>> =
            Arc::new(Mutex::new(HashMap::new()));
        // ETag + body caches for per-endpoint conditional GETs (get_pr_head_sha,
        // fetch_check_runs_state, get_our_last_review).  Keyed by full URL so
        // a single map covers all three endpoints without collisions.
        let endpoint_etags: Arc<Mutex<HashMap<String, String>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let endpoint_body_cache: Arc<Mutex<HashMap<String, String>>> =
            Arc::new(Mutex::new(HashMap::new()));

        // Path to the approvals JSONL signal file.
        let approvals_path = self.config.perri_state_dir().join("approvals.jsonl");

        loop {
            // Consume any approvals that arrived since the last cycle (or since
            // startup).  Belt-and-suspenders: the approvals_rx branch in the
            // select! below also triggers an immediate re-fetch when the file
            // appears, but we consume here unconditionally so a write that races
            // past the watcher is never missed.
            {
                let mut store = suppress.lock().unwrap();
                let count = store.consume_approvals_file(&approvals_path, unix_now_secs());
                if count > 0 {
                    store.save();
                    debug!("perri suppress: consumed {count} new approval(s) before fetch");
                }
            }

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
                        continue;
                    }
                },
            };

            match self
                .fetch(
                    &client,
                    &me_login,
                    &mut etags,
                    &mut item_cache,
                    &mut last_seen_updated,
                    &mut review_state_cache,
                    &head_sha_cache,
                    &ci_state_cache,
                    &endpoint_etags,
                    &endpoint_body_cache,
                    &suppress,
                )
                .await
            {
                Ok(snap) => {
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

                    // Pre-fetch detail for the top-3 PRs in bucket-priority order.
                    let top_three = top_three_items(&snap.items);
                    for item in top_three {
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
                            if let Err(e) =
                                prefetch_into_cache(&cfg, &client_clone, &repo, number).await
                            {
                                debug!("perri prefetch {repo}#{number} failed: {e:#}");
                            }
                        });
                    }

                    let _ = tx.send(Some(snap));
                }
                Err(e) => {
                    warn!("perri queue fetch failed: {e:#}");
                    let mut snap = tx.borrow().clone().unwrap_or_default();
                    snap.stale = true;
                    snap.error = Some(e.to_string());
                    let _ = tx.send(Some(snap));
                }
            }

            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_secs(interval_secs)) => {}
                // `Some(_) = ...` disables the branch when the channel is
                // closed (recv() yields None).  The plain `_ = recv()` form
                // matches None too, which causes the branch to fire on every
                // poll once the sender is dropped — producing a tight loop
                // that hammers the GitHub search API.
                Some(_) = dirty_rx.recv() => {
                    debug!("perri queue dirty-file signal");
                }
                Some(_) = refresh_rx.recv() => {
                    debug!("perri queue direct-push refresh signal (MCP)");
                }
                Some(_) = approvals_rx.recv() => {
                    debug!("perri queue approvals-file signal — re-fetching with new suppression");
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    async fn fetch(
        &self,
        client: &GithubClient,
        me: &str,
        etags: &mut HashMap<String, String>,
        item_cache: &mut HashMap<String, Vec<SearchIssueItem>>,
        last_seen_updated: &mut HashMap<(String, u64), String>,
        review_state_cache: &mut HashMap<(String, u64), (String, Option<String>)>,
        head_sha_cache: &Arc<Mutex<HashMap<(String, u64), String>>>,
        ci_state_cache: &Arc<Mutex<HashMap<String, (CiState, bool)>>>,
        endpoint_etags: &Arc<Mutex<HashMap<String, String>>>,
        endpoint_body_cache: &Arc<Mutex<HashMap<String, String>>>,
        suppress: &Arc<Mutex<SuppressStore>>,
    ) -> Result<PrQueueSnapshot> {
        // ── Run the three search queries ──────────────────────────────────────
        let q_requested =
            "is:open is:pr review-requested:@me org:Carefeed archived:false".to_owned();
        let q_needs = "is:open is:pr review:required org:Carefeed archived:false".to_owned();
        let q_reviewed = "is:open is:pr reviewed-by:@me org:Carefeed archived:false".to_owned();

        // Searches must run sequentially because they share the mutable ETag
        // and item caches.  This is fine — the poll interval is 60s.
        let requested_items = search_issues(client, &q_requested, etags, item_cache).await?;
        let needs_items = search_issues(client, &q_needs, etags, item_cache).await?;
        let reviewed_items = search_issues(client, &q_reviewed, etags, item_cache).await?;

        debug!(
            me,
            requested = requested_items.len(),
            needs = needs_items.len(),
            reviewed = reviewed_items.len(),
            "perri queue search results"
        );

        // ── Build bucket 1 & 2 candidates (dedup, basic filters) ─────────────
        // requested takes priority; needs_review fills in the rest.
        let requested_urls: std::collections::HashSet<&str> = requested_items
            .iter()
            .map(|i| i.html_url.as_str())
            .collect();

        let b12_candidates: Vec<(SearchIssueItem, &str)> = requested_items
            .iter()
            .map(|i| (i.clone(), "requested"))
            .chain(
                needs_items
                    .iter()
                    .filter(|i| !requested_urls.contains(i.html_url.as_str()))
                    .map(|i| (i.clone(), "needs_review")),
            )
            .filter_map(|(i, original_bucket)| {
                if is_filtered(&i, me) {
                    debug!(
                        url = %i.html_url,
                        author = i.user.as_ref().map(|u| u.login.as_str()).unwrap_or("(none)"),
                        draft = i.draft.unwrap_or(false),
                        "is_filtered: dropping"
                    );
                    return None;
                }
                // Bot-authored PRs land in the "dependabot" bucket instead of the
                // human-review bucket they were discovered in.
                let author = i.user.as_ref().map(|u| u.login.as_str()).unwrap_or("");
                let effective_bucket = if is_bot(author) { "dependabot" } else { original_bucket };
                Some((i, effective_bucket))
            })
            .collect();

        debug!(b12_candidates = b12_candidates.len(), "after is_filtered");

        // ── CI-filter buckets 1 & 2 concurrently ─────────────────────────────
        let b12_futures: Vec<_> = b12_candidates
            .into_iter()
            .map(|(item, bucket)| {
                let client = client.clone();
                let head_sha_cache = Arc::clone(head_sha_cache);
                let ci_state_cache = Arc::clone(ci_state_cache);
                let endpoint_etags = Arc::clone(endpoint_etags);
                let endpoint_body_cache = Arc::clone(endpoint_body_cache);
                async move {
                    let repo = repo_from_url(&item.repository_url);
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
                    if failed {
                        return None;
                    }
                    let author = item
                        .user
                        .as_ref()
                        .map(|u| u.login.clone())
                        .unwrap_or_default();
                    let item_is_bot = is_bot(&author);
                    Some(PrQueueItem {
                        repo,
                        number: item.number,
                        title: item.title.clone(),
                        author,
                        bucket: bucket.to_owned(),
                        new_activity: false,
                        url: item.html_url.clone(),
                        ci_state,
                        head_sha,
                        is_bot: item_is_bot,
                    })
                }
            })
            .collect();

        let b12_items: Vec<PrQueueItem> = futures::future::join_all(b12_futures)
            .await
            .into_iter()
            .flatten()
            .collect();

        debug!(b12_items = b12_items.len(), "after CI filter");

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

        // URLs already covered by buckets 1 & 2 — skip in bucket 3
        let known_urls: std::collections::HashSet<&str> =
            b12_items.iter().map(|i| i.url.as_str()).collect();

        // ── Bucket 3: changes_req with new_activity ───────────────────────────
        // For each reviewed-by-me PR not already in b1/b2:
        //   - fetch our last review state via the reviews API
        //   - include only if state == CHANGES_REQUESTED and updated_at > submitted_at + 30s
        let b3_candidates: Vec<&SearchIssueItem> = reviewed_items
            .iter()
            .filter(|i| !known_urls.contains(i.html_url.as_str()))
            .filter(|i| !is_filtered(i, me))
            .collect();

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
                    last_seen_updated,
                    review_state_cache,
                );

                let head_sha_cache = Arc::clone(head_sha_cache);
                let ci_state_cache = Arc::clone(ci_state_cache);
                let endpoint_etags = Arc::clone(endpoint_etags);
                let endpoint_body_cache = Arc::clone(endpoint_body_cache);
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
                            None => return (key, None, None),
                        },
                    };

                    if state != "CHANGES_REQUESTED" {
                        return (key, None, new_cache_entry);
                    }

                    // Only include if the author has responded since our review
                    // (30s grace window to avoid self-triggering on our own submission).
                    let new_activity = match (&submitted_at, &item.updated_at) {
                        (Some(rev_ts), Some(pr_ts)) => {
                            let review_epoch = parse_epoch(rev_ts);
                            let pr_epoch = parse_epoch(pr_ts);
                            pr_epoch.saturating_sub(review_epoch) > 30
                        }
                        _ => false,
                    };

                    if !new_activity {
                        return (key, None, new_cache_entry);
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
                    if failed {
                        return (key, None, new_cache_entry);
                    }

                    let b3_author = item
                        .user
                        .as_ref()
                        .map(|u| u.login.clone())
                        .unwrap_or_default();
                    let b3_is_bot = is_bot(&b3_author);
                    let pr_item = PrQueueItem {
                        repo,
                        number: item.number,
                        title: item.title.clone(),
                        author: b3_author,
                        bucket: if b3_is_bot { "dependabot".to_owned() } else { "changes_req".to_owned() },
                        new_activity: !b3_is_bot,
                        url: item.html_url.clone(),
                        ci_state,
                        head_sha,
                        is_bot: b3_is_bot,
                    };
                    (key, Some(pr_item), new_cache_entry)
                }
            })
            .collect();

        // Reduce: flush new review-state entries into the cache and collect items.
        let mut b3_items: Vec<PrQueueItem> = Vec::new();
        for (key, item, new_entry) in futures::future::join_all(b3_futures).await {
            if let Some(entry) = new_entry {
                review_state_cache.insert(key, entry);
            }
            if let Some(pr) = item {
                b3_items.push(pr);
            }
        }

        // Record latest updated_at for every reviewed PR so future cycles can skip
        // unchanged ones (including PRs that fell into b1/b2 this cycle).
        for item in &reviewed_items {
            if let Some(updated_at) = &item.updated_at {
                let repo = repo_from_url(&item.repository_url);
                last_seen_updated.insert((repo, item.number), updated_at.clone());
            }
        }

        let mut items: Vec<PrQueueItem> = b12_items.into_iter().chain(b3_items).collect();

        // ── Apply approval suppression ────────────────────────────────────────
        // Prune expired entries then filter out any PR whose current head_sha
        // exactly matches a live suppression entry.  PRs with an empty head_sha
        // (unresolved) are never suppressed — an empty string cannot match a
        // real recorded sha (is_suppressed() guards this explicitly).
        {
            let now = unix_now_secs();
            let mut store = suppress.lock().unwrap();
            if store.prune(now) {
                store.save();
            }
            let before = items.len();
            items.retain(|item| {
                !store.is_suppressed(&item.repo, item.number, &item.head_sha, now)
            });
            let suppressed = before - items.len();
            if suppressed > 0 {
                debug!("perri suppress: hid {suppressed} just-approved PR(s) from snapshot");
            }
        }

        Ok(PrQueueSnapshot {
            generated_at: Some(Utc::now()),
            items,
            stale: false,
            error: None,
        })
    }

    fn build_client(&self) -> Result<GithubClient> {
        let hosts_path = self.config.github_token_path.as_deref();
        GithubClient::new(hosts_path)
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Returns `true` if the GitHub login belongs to a known bot that should be
/// routed into the `"dependabot"` bucket rather than the human-review buckets.
///
/// This is the **single source of truth** for bot identity — the `review-prs`
/// skill delegates to the daemon queue's `is_bot` field and does not maintain
/// its own dependabot-discovery query.
pub(crate) fn is_bot(author: &str) -> bool {
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
    let url = format!("{}/repos/{repo}/pulls/{number}/reviews", api_base());
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

    // Record current head SHA (brief lock, no await).
    head_sha_cache
        .lock()
        .unwrap()
        .insert((repo.to_owned(), number), sha.clone());

    // Return cached result if the SHA hasn't changed since last cycle.
    // Only cache terminal states (Success, Failure) — Pending is transitional
    // and must re-fetch each cycle so we detect when checks complete.
    {
        let lock = ci_state_cache.lock().unwrap();
        if let Some(&(state, failed)) = lock.get(&sha) {
            if state != CiState::Pending && state != CiState::Unknown {
                debug!(%repo, number, "ci_state cache hit (sha unchanged)");
                return (state, failed, sha);
            }
        }
    }

    // Cache miss — fetch check-runs and store the result.
    let result =
        fetch_check_runs_state(client, repo, &sha, endpoint_etags, endpoint_body_cache).await;
    ci_state_cache.lock().unwrap().insert(sha.clone(), result);
    (result.0, result.1, sha)
}

/// Fetch and parse check-runs for a known HEAD SHA.
///
/// Returns `(display_state, actions_failure_filter)`:
/// - `display_state` — rolled-up `CiState` over all check-runs (D1)
/// - `actions_failure_filter` — `true` iff a GitHub Actions run has
///   `conclusion == "failure"` (preserves the old check-suites filter
///   semantics, D2)
async fn fetch_check_runs_state(
    client: &GithubClient,
    repo: &str,
    sha: &str,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> (CiState, bool) {
    let url = format!(
        "{}/repos/{repo}/commits/{sha}/check-runs?per_page=100",
        api_base()
    );
    let body = match etag_get(client, &url, etags, body_cache).await {
        Some(b) => b,
        None => return (CiState::Unknown, false),
    };

    let resp: CheckRunsResponse = match serde_json::from_str(&body) {
        Ok(r) => r,
        Err(_) => return (CiState::Unknown, false),
    };

    let display_state = CiState::rollup(
        resp.check_runs
            .iter()
            .map(|r| CiState::from_check(r.status.as_deref(), r.conclusion.as_deref())),
    );

    let actions_failure = resp.check_runs.iter().any(|r| {
        r.app.as_ref().and_then(|a| a.slug.as_deref()) == Some("github-actions")
            && CiState::from_check(r.status.as_deref(), r.conclusion.as_deref()) == CiState::Failure
    });

    (display_state, actions_failure)
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
async fn etag_get(
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
fn base_headers(client: &GithubClient) -> HeaderMap {
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
pub(crate) fn write_json_atomic(path: &Path, json: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json)?;
    std::fs::rename(&tmp, path)
}

/// Select the top-3 PRs in bucket-priority order:
/// `requested` → `needs_review` → `changes_req` → `dependabot`; preserve within-bucket order.
///
/// Dependabot PRs sit last — they rarely require reading the diff, so prefetching
/// them over a human-review PR wastes the limited prefetch budget.
fn top_three_items(items: &[PrQueueItem]) -> Vec<&PrQueueItem> {
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
            assert!(is_bot(login), "expected '{login}' to be recognised as a bot");
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
        let mut etags = HashMap::new();
        let mut item_cache = HashMap::new();
        let mut last_seen = HashMap::new();
        let mut review_cache = HashMap::new();
        let head_sha_cache = Arc::new(Mutex::new(HashMap::new()));
        let ci_state_cache = Arc::new(Mutex::new(HashMap::new()));
        let endpoint_etags = Arc::new(Mutex::new(HashMap::new()));
        let endpoint_body = Arc::new(Mutex::new(HashMap::new()));
        source
            .fetch(
                &client,
                "tester",
                &mut etags,
                &mut item_cache,
                &mut last_seen,
                &mut review_cache,
                &head_sha_cache,
                &ci_state_cache,
                &endpoint_etags,
                &endpoint_body,
                &suppress,
            )
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
            .and(query_param("q", "is:open is:pr review-requested:@me org:Carefeed archived:false"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(server)
            .await;

        // review:required — returns PR #42
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param("q", "is:open is:pr review:required org:Carefeed archived:false"))
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
            .and(query_param("q", "is:open is:pr reviewed-by:@me org:Carefeed archived:false"))
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
            snap.items.len(), 1,
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
        assert_eq!(snap.items.len(), 1, "unsuppressed PR should appear in snapshot");
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
            .and(query_param("q", "is:open is:pr review-requested:@me org:Carefeed archived:false"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(server)
            .await;

        let head_sha_owned = head_sha.to_owned();
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param("q", "is:open is:pr review:required org:Carefeed archived:false"))
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
            .and(query_param("q", "is:open is:pr reviewed-by:@me org:Carefeed archived:false"))
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

        assert_eq!(snap.items.len(), 1, "dependabot PR should appear in snapshot");
        let item = &snap.items[0];
        assert_eq!(item.number, 100);
        assert_eq!(item.bucket, "dependabot", "dependabot PR must land in 'dependabot' bucket");
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
            .and(query_param("q", "is:open is:pr review-requested:@me org:Carefeed archived:false"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(server)
            .await;

        // Search index still returns PR #55 as open (lag)
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param("q", "is:open is:pr review:required org:Carefeed archived:false"))
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
            .and(query_param("q", "is:open is:pr reviewed-by:@me org:Carefeed archived:false"))
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
            .and(query_param("q", "is:open is:pr review-requested:@me org:Carefeed archived:false"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": []})))
            .mount(&server)
            .await;

        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param("q", "is:open is:pr review:required org:Carefeed archived:false"))
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
            .and(query_param("q", "is:open is:pr reviewed-by:@me org:Carefeed archived:false"))
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
}
