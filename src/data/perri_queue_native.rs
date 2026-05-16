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
use std::sync::{Arc, Mutex};

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
        perri_queue::{PrQueueItem, PrQueueSnapshot},
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
}

#[derive(Deserialize)]
struct PrHead {
    sha: String,
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
    pub fn spawn(config: Config) -> (watch::Receiver<Option<PrQueueSnapshot>>, mpsc::UnboundedSender<()>) {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();
        let (refresh_tx, mut refresh_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.perri_state_dir().join("queue.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        let interval_secs = config.pr_queue_poll_secs;

        tokio::spawn(async move {
            let source = PerriQueueNativeSource { config };
            source.run(tx, &mut dirty_rx, &mut refresh_rx, interval_secs).await;
        });

        (rx, refresh_tx)
    }

    async fn run(
        &self,
        tx: watch::Sender<Option<PrQueueSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
        refresh_rx: &mut mpsc::UnboundedReceiver<()>,
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
        // the check-suites call when the HEAD SHA hasn't changed.
        let head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let ci_failure_cache: Arc<Mutex<HashMap<String, bool>>> =
            Arc::new(Mutex::new(HashMap::new()));

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
                    &ci_failure_cache,
                )
                .await
            {
                Ok(snap) => {
                    debug!(prs = snap.items.len(), "perri queue refreshed");
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
                _ = dirty_rx.recv() => {
                    debug!("perri queue dirty-file signal");
                }
                _ = refresh_rx.recv() => {
                    debug!("perri queue direct-push refresh signal (MCP)");
                }
            }
        }
    }

    async fn fetch(
        &self,
        client: &GithubClient,
        me: &str,
        etags: &mut HashMap<String, String>,
        item_cache: &mut HashMap<String, Vec<SearchIssueItem>>,
        last_seen_updated: &mut HashMap<(String, u64), String>,
        review_state_cache: &mut HashMap<(String, u64), (String, Option<String>)>,
        head_sha_cache: &Arc<Mutex<HashMap<(String, u64), String>>>,
        ci_failure_cache: &Arc<Mutex<HashMap<String, bool>>>,
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
            .filter(|(i, _)| !is_filtered(i, me))
            .collect();

        // ── CI-filter buckets 1 & 2 concurrently ─────────────────────────────
        let b12_futures: Vec<_> = b12_candidates
            .into_iter()
            .map(|(item, bucket)| {
                let client = client.clone();
                let head_sha_cache = Arc::clone(head_sha_cache);
                let ci_failure_cache = Arc::clone(ci_failure_cache);
                async move {
                    let repo = repo_from_url(&item.repository_url);
                    if ci_has_failure_cached(
                        &client,
                        &repo,
                        item.number,
                        &head_sha_cache,
                        &ci_failure_cache,
                    )
                    .await
                    {
                        return None;
                    }
                    Some(PrQueueItem {
                        repo,
                        number: item.number,
                        title: item.title.clone(),
                        author: item
                            .user
                            .as_ref()
                            .map(|u| u.login.clone())
                            .unwrap_or_default(),
                        bucket: bucket.to_owned(),
                        new_activity: false,
                        url: item.html_url.clone(),
                    })
                }
            })
            .collect();

        let b12_items: Vec<PrQueueItem> = futures::future::join_all(b12_futures)
            .await
            .into_iter()
            .flatten()
            .collect();

        // Prune ci_failure_cache: remove SHA entries that are no longer referenced
        // by any current PR head.  Runs after every cycle — the set is tiny.
        {
            let current_shas: std::collections::HashSet<String> = head_sha_cache
                .lock()
                .unwrap()
                .values()
                .cloned()
                .collect();
            ci_failure_cache
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
                let ci_failure_cache = Arc::clone(ci_failure_cache);
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
                        None => match get_our_last_review(&client, &repo, item.number, &me).await
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

                    if ci_has_failure_cached(
                        &client,
                        &repo,
                        item.number,
                        &head_sha_cache,
                        &ci_failure_cache,
                    )
                    .await
                    {
                        return (key, None, new_cache_entry);
                    }

                    let pr_item = PrQueueItem {
                        repo,
                        number: item.number,
                        title: item.title.clone(),
                        author: item
                            .user
                            .as_ref()
                            .map(|u| u.login.clone())
                            .unwrap_or_default(),
                        bucket: "changes_req".to_owned(),
                        new_activity: true,
                        url: item.html_url.clone(),
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

        let items: Vec<PrQueueItem> = b12_items.into_iter().chain(b3_items).collect();

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

/// Returns `true` if the item should be excluded from all buckets:
/// draft PRs, self-authored PRs, and known bot accounts.
fn is_filtered(item: &SearchIssueItem, me: &str) -> bool {
    if item.draft.unwrap_or(false) {
        return true;
    }
    let author = item.user.as_ref().map(|u| u.login.as_str()).unwrap_or("");
    if author == me {
        return true;
    }
    // Drop well-known bots.
    matches!(author, "dependabot" | "dependabot[bot]" | "carefeed-ci")
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
        .get("https://api.github.com/user")
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
        "https://api.github.com/search/issues?q={}&per_page=100",
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
async fn get_our_last_review(
    client: &GithubClient,
    repo: &str,
    number: u64,
    me: &str,
) -> Option<(String, Option<String>)> {
    let url = format!("https://api.github.com/repos/{repo}/pulls/{number}/reviews");
    let resp = client
        .http
        .get(&url)
        .headers(base_headers(client))
        .send()
        .await
        .ok()?;

    if !resp.status().is_success() {
        return None;
    }

    let reviews: Vec<ReviewItem> = resp.json().await.ok()?;
    // Find our last review (last in the list wins).
    reviews
        .into_iter()
        .rfind(|r| r.user.as_ref().map(|u| u.login.as_str()) == Some(me))
        .map(|r| (r.state, r.submitted_at))
}

/// Returns `true` if any GitHub Actions check suite on the PR's HEAD commit
/// has `conclusion = "failure"`.  Results are cached by HEAD SHA so that
/// successive cycles skip the check-suites HTTP call when the PR hasn't
/// received a new push.
///
/// The Mutex guards are held only for brief HashMap operations — never across
/// an `.await` point.
pub async fn ci_has_failure_cached(
    client: &GithubClient,
    repo: &str,
    number: u64,
    head_sha_cache: &Arc<Mutex<HashMap<(String, u64), String>>>,
    ci_failure_cache: &Arc<Mutex<HashMap<String, bool>>>,
) -> bool {
    let sha = match get_pr_head_sha(client, repo, number).await {
        Some(s) => s,
        None => return false,
    };

    // Record current head SHA (brief lock, no await).
    head_sha_cache
        .lock()
        .unwrap()
        .insert((repo.to_owned(), number), sha.clone());

    // Return cached result if the SHA hasn't changed since last cycle.
    {
        let lock = ci_failure_cache.lock().unwrap();
        if let Some(&cached) = lock.get(&sha) {
            debug!(%repo, number, "ci_failure cache hit (sha unchanged)");
            return cached;
        }
    }

    // Cache miss — fetch check suites and store the result.
    let result = fetch_check_suites_failure(client, repo, &sha).await;
    ci_failure_cache.lock().unwrap().insert(sha, result);
    result
}

/// Fetch the check-suites result for a known HEAD SHA.
///
/// Extracted from the old `ci_has_failure` body so it can be reused by both
/// the cached path and tests.
pub async fn fetch_check_suites_failure(client: &GithubClient, repo: &str, sha: &str) -> bool {
    let url = format!("{}/repos/{repo}/commits/{sha}/check-suites", api_base());
    let resp = match client
        .http
        .get(&url)
        .headers(base_headers(client))
        .send()
        .await
    {
        Ok(r) => r,
        Err(_) => return false,
    };

    if !resp.status().is_success() {
        return false;
    }

    let suites: CheckSuitesResponse = match resp.json().await {
        Ok(s) => s,
        Err(_) => return false,
    };

    suites.check_suites.iter().any(|s| {
        s.app.as_ref().map(|a| a.name.as_str()) == Some("GitHub Actions")
            && s.conclusion.as_deref() == Some("failure")
    })
}

async fn get_pr_head_sha(client: &GithubClient, repo: &str, number: u64) -> Option<String> {
    let url = format!("{}/repos/{repo}/pulls/{number}", api_base());
    let resp = client
        .http
        .get(&url)
        .headers(base_headers(client))
        .send()
        .await
        .ok()?;

    if !resp.status().is_success() {
        return None;
    }

    let pr: PrDetail = resp.json().await.ok()?;
    Some(pr.head.sha)
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

    fn make_item(login: &str, draft: bool, updated_at: Option<&str>) -> SearchIssueItem {
        SearchIssueItem {
            number: 1,
            title: "Test PR".to_owned(),
            html_url: "https://github.com/Carefeed/care/pull/1".to_owned(),
            repository_url: "https://api.github.com/repos/Carefeed/care".to_owned(),
            user: Some(GhUser { login: login.to_owned() }),
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
        rev_cache.insert(key.clone(), ("CHANGES_REQUESTED".to_owned(), Some(ts.clone())));

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
    fn is_filtered_excludes_known_bots() {
        for bot in &["dependabot", "dependabot[bot]", "carefeed-ci"] {
            assert!(
                is_filtered(&make_item(bot, false, None), "hammer"),
                "expected bot '{bot}' to be filtered"
            );
        }
    }

    #[test]
    fn is_filtered_passes_normal_prs() {
        assert!(!is_filtered(&make_item("alice", false, None), "hammer"));
    }
}
