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
//! response reuses the in-memory cache without re-processing.  The three
//! per-PR endpoint calls (`get_pr_head_sha`, check-suites, `get_our_last_review`)
//! also use ETag conditional GETs via [`etag_get`].  Additionally, CI results
//! are cached by HEAD SHA so successive cycles skip the check-suites call when
//! the PR hasn't received a new push.

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
// Always compiled so integration tests can override without feature flags.

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
        // ETag + body caches for per-endpoint calls (keyed by URL).
        // Wrapped in Arc<Mutex> so concurrent join_all futures can share them.
        let endpoint_etags: Arc<Mutex<HashMap<String, String>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let endpoint_bodies: Arc<Mutex<HashMap<String, String>>> =
            Arc::new(Mutex::new(HashMap::new()));
        // SHA cache: (repo, number) → last-seen HEAD SHA, used to skip CI calls
        // when the PR hasn't received a new push.
        let head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>> =
            Arc::new(Mutex::new(HashMap::new()));
        // CI result cache: SHA → has_failure, invalidated only when SHA changes.
        let ci_failure_cache: Arc<Mutex<HashMap<String, bool>>> =
            Arc::new(Mutex::new(HashMap::new()));
        // Authenticated user login — fetched once and reused.
        let mut me: Option<String> = None;

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
                    Arc::clone(&endpoint_etags),
                    Arc::clone(&endpoint_bodies),
                    Arc::clone(&head_sha_cache),
                    Arc::clone(&ci_failure_cache),
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

    #[allow(clippy::too_many_arguments)]
    async fn fetch(
        &self,
        client: &GithubClient,
        me: &str,
        etags: &mut HashMap<String, String>,
        item_cache: &mut HashMap<String, Vec<SearchIssueItem>>,
        endpoint_etags: Arc<Mutex<HashMap<String, String>>>,
        endpoint_bodies: Arc<Mutex<HashMap<String, String>>>,
        head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>>,
        ci_failure_cache: Arc<Mutex<HashMap<String, bool>>>,
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
                let ep_etags = Arc::clone(&endpoint_etags);
                let ep_bodies = Arc::clone(&endpoint_bodies);
                let head_sha_cache = Arc::clone(&head_sha_cache);
                let ci_failure_cache = Arc::clone(&ci_failure_cache);
                async move {
                    let repo = repo_from_url(&item.repository_url);
                    if ci_has_failure(
                        &client,
                        &repo,
                        item.number,
                        &ep_etags,
                        &ep_bodies,
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

        // Prune ci_failure_cache: drop SHA entries no longer referenced by any
        // current PR head.  Runs after every cycle — the set is tiny.
        {
            let current_shas: std::collections::HashSet<String> =
                head_sha_cache.lock().unwrap().values().cloned().collect();
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

        let b3_futures: Vec<_> = b3_candidates
            .into_iter()
            .map(|item| {
                let client = client.clone();
                let me = me.to_owned();
                let ep_etags = Arc::clone(&endpoint_etags);
                let ep_bodies = Arc::clone(&endpoint_bodies);
                let head_sha_cache = Arc::clone(&head_sha_cache);
                let ci_failure_cache = Arc::clone(&ci_failure_cache);
                async move {
                    let repo = repo_from_url(&item.repository_url);
                    let (state, submitted_at) =
                        get_our_last_review(&client, &repo, item.number, &me, &ep_etags, &ep_bodies)
                            .await?;

                    if state != "CHANGES_REQUESTED" {
                        return None;
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
                        return None;
                    }

                    if ci_has_failure(
                        &client,
                        &repo,
                        item.number,
                        &ep_etags,
                        &ep_bodies,
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
                        bucket: "changes_req".to_owned(),
                        new_activity: true,
                        url: item.html_url.clone(),
                    })
                }
            })
            .collect();

        let b3_items: Vec<PrQueueItem> = futures::future::join_all(b3_futures)
            .await
            .into_iter()
            .flatten()
            .collect();

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
/// Uses ETag conditional GET — 304 responses are free from the rate-limit budget.
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

/// Returns `true` if any GitHub Actions check suite on the PR's HEAD commit
/// has `conclusion = "failure"`.
///
/// Two layers of caching:
/// 1. **SHA cache** — if the HEAD SHA hasn't changed since last cycle, returns
///    the cached boolean without any HTTP call.
/// 2. **ETag cache** — on a new SHA, `get_pr_head_sha` and `fetch_check_suites`
///    use conditional GETs so 304 responses don't consume rate-limit budget.
///
/// On any API error, returns `false` (safe default).
async fn ci_has_failure(
    client: &GithubClient,
    repo: &str,
    number: u64,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
    head_sha_cache: &Arc<Mutex<HashMap<(String, u64), String>>>,
    ci_failure_cache: &Arc<Mutex<HashMap<String, bool>>>,
) -> bool {
    let sha = match get_pr_head_sha(client, repo, number, etags, body_cache).await {
        Some(s) => s,
        None => return false,
    };

    // Record current head SHA (brief lock, no await).
    head_sha_cache
        .lock()
        .unwrap()
        .insert((repo.to_owned(), number), sha.clone());

    // Return cached result if SHA hasn't changed since last cycle.
    {
        let lock = ci_failure_cache.lock().unwrap();
        if let Some(&cached) = lock.get(&sha) {
            debug!(%repo, number, "ci_failure cache hit (sha unchanged)");
            return cached;
        }
    }

    // Cache miss — fetch check suites and store the result.
    let result = fetch_check_suites_failure(client, repo, &sha, etags, body_cache).await;
    ci_failure_cache.lock().unwrap().insert(sha, result);
    result
}

async fn get_pr_head_sha(
    client: &GithubClient,
    repo: &str,
    number: u64,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<String> {
    let url = format!("{}/repos/{repo}/pulls/{number}", api_base());
    let body = etag_get(client, &url, etags, body_cache).await?;
    let pr: PrDetail = serde_json::from_str(&body).ok()?;
    Some(pr.head.sha)
}

/// Fetch the check-suites result for a known HEAD SHA using a conditional GET.
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

/// Conditional GET helper.
///
/// Sends `If-None-Match` when an ETag is known for `url`.  On 304, returns the
/// cached body.  On 200, stores the new ETag + body and returns the body.
/// On any error or non-2xx response, returns `None` without clobbering an
/// existing cached value — this ensures a transient error never evicts a good
/// ETag, so the next call will still send `If-None-Match` correctly.
///
/// Bodies are stored as raw strings; callers are responsible for
/// `serde_json::from_str` so this helper stays type-agnostic.
async fn etag_get(
    client: &GithubClient,
    url: &str,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<String> {
    let existing_etag = etags.lock().ok()?.get(url).cloned();
    let mut headers = base_headers(client);
    if let Some(ref etag) = existing_etag {
        if let Ok(v) = etag.parse() {
            headers.insert(IF_NONE_MATCH, v);
        }
    }

    let resp = client.http.get(url).headers(headers).send().await.ok()?;

    // Capture the new ETag before consuming the response (even on 304).
    if let Some(etag) = resp.headers().get("etag").and_then(|v| v.to_str().ok()) {
        etags.lock().ok()?.insert(url.to_owned(), etag.to_owned());
    }

    if resp.status() == reqwest::StatusCode::NOT_MODIFIED {
        return body_cache.lock().ok()?.get(url).cloned();
    }

    if !resp.status().is_success() {
        return None;
    }

    let body = resp.text().await.ok()?;
    body_cache.lock().ok()?.insert(url.to_owned(), body.clone());
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

// ── URL encoding ──────────────────────────────────────────────────────────────

mod urlencoding {
    pub fn encode(s: &str) -> String {
        url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    use crate::data::github_client::GithubClient;

    use super::etag_get;

    type SharedStrMap = Arc<Mutex<HashMap<String, String>>>;

    fn make_client() -> GithubClient {
        // Set a fake token so GithubClient::new(None) succeeds without
        // touching the filesystem.
        std::env::set_var("GITHUB_TOKEN", "test-token");
        GithubClient::new(None).expect("client")
    }

    fn empty_caches() -> (SharedStrMap, SharedStrMap) {
        (
            Arc::new(Mutex::new(HashMap::new())),
            Arc::new(Mutex::new(HashMap::new())),
        )
    }

    // ── 1. First call: no If-None-Match, 200 stores ETag + body ──────────────

    #[tokio::test]
    async fn etag_get_first_call_sends_no_if_none_match() {
        let server = MockServer::start().await;
        let client = make_client();
        let (etags, bodies) = empty_caches();

        Mock::given(method("GET"))
            .and(path("/resource"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("etag", "\"abc123\"")
                    .set_body_string(r#"{"head":{"sha":"deadbeef"}}"#),
            )
            .expect(1)
            .mount(&server)
            .await;

        let url = format!("{}/resource", server.uri());
        let body = etag_get(&client, &url, &etags, &bodies).await;

        assert!(body.is_some(), "should return body on 200");
        assert_eq!(
            etags.lock().unwrap().get(&url).cloned().as_deref(),
            Some("\"abc123\""),
            "ETag should be stored"
        );
        assert_eq!(
            bodies.lock().unwrap().get(&url).cloned().as_deref(),
            Some(r#"{"head":{"sha":"deadbeef"}}"#),
            "body should be cached"
        );
    }

    // ── 2. Second call: sends If-None-Match, 304 returns cached body ──────────

    #[tokio::test]
    async fn etag_get_second_call_sends_if_none_match_and_304_returns_cached_body() {
        let server = MockServer::start().await;
        let client = make_client();
        let (etags, bodies) = empty_caches();

        // Prime the caches as if a first fetch already happened.
        let url = format!("{}/resource", server.uri());
        etags
            .lock()
            .unwrap()
            .insert(url.clone(), "\"abc123\"".to_owned());
        bodies
            .lock()
            .unwrap()
            .insert(url.clone(), r#"{"cached":"body"}"#.to_owned());

        // Expect exactly one request that INCLUDES If-None-Match.
        Mock::given(method("GET"))
            .and(path("/resource"))
            .and(header("If-None-Match", "\"abc123\""))
            .respond_with(ResponseTemplate::new(304))
            .expect(1)
            .mount(&server)
            .await;

        let result = etag_get(&client, &url, &etags, &bodies).await;

        assert_eq!(
            result.as_deref(),
            Some(r#"{"cached":"body"}"#),
            "304 should return cached body"
        );
    }

    // ── 3. 200 with new ETag updates both caches ──────────────────────────────

    #[tokio::test]
    async fn etag_get_200_with_new_etag_updates_both_caches() {
        let server = MockServer::start().await;
        let client = make_client();
        let (etags, bodies) = empty_caches();

        let url = format!("{}/resource", server.uri());
        // Seed with an old ETag.
        etags
            .lock()
            .unwrap()
            .insert(url.clone(), "\"old-etag\"".to_owned());
        bodies
            .lock()
            .unwrap()
            .insert(url.clone(), r#"{"old":"body"}"#.to_owned());

        Mock::given(method("GET"))
            .and(path("/resource"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("etag", "\"new-etag\"")
                    .set_body_string(r#"{"new":"body"}"#),
            )
            .expect(1)
            .mount(&server)
            .await;

        let result = etag_get(&client, &url, &etags, &bodies).await;

        assert_eq!(result.as_deref(), Some(r#"{"new":"body"}"#));
        assert_eq!(
            etags.lock().unwrap().get(&url).cloned().as_deref(),
            Some("\"new-etag\""),
            "ETag should be updated"
        );
        assert_eq!(
            bodies.lock().unwrap().get(&url).cloned().as_deref(),
            Some(r#"{"new":"body"}"#),
            "body cache should be updated"
        );
    }

    // ── 4. Transient error does not evict ETag or body ────────────────────────

    #[tokio::test]
    async fn etag_get_transient_error_preserves_etag_and_body_cache() {
        let server = MockServer::start().await;
        let client = make_client();
        let (etags, bodies) = empty_caches();

        let url = format!("{}/resource", server.uri());
        etags
            .lock()
            .unwrap()
            .insert(url.clone(), "\"good-etag\"".to_owned());
        bodies
            .lock()
            .unwrap()
            .insert(url.clone(), r#"{"good":"body"}"#.to_owned());

        Mock::given(method("GET"))
            .and(path("/resource"))
            .respond_with(ResponseTemplate::new(500))
            .expect(1)
            .mount(&server)
            .await;

        let result = etag_get(&client, &url, &etags, &bodies).await;

        assert!(result.is_none(), "500 should return None");
        // ETag and body must be intact — next call will retry with If-None-Match.
        assert_eq!(
            etags.lock().unwrap().get(&url).cloned().as_deref(),
            Some("\"good-etag\""),
            "ETag must not be evicted on error"
        );
        assert_eq!(
            bodies.lock().unwrap().get(&url).cloned().as_deref(),
            Some(r#"{"good":"body"}"#),
            "body cache must not be evicted on error"
        );
    }

    // ── 5. 304 with empty body cache returns None gracefully ──────────────────

    #[tokio::test]
    async fn etag_get_304_with_empty_body_cache_returns_none() {
        let server = MockServer::start().await;
        let client = make_client();
        let (etags, bodies) = empty_caches();

        let url = format!("{}/resource", server.uri());
        // ETag present but body cache is empty (orphan state — shouldn't happen
        // in practice but must not panic).
        etags
            .lock()
            .unwrap()
            .insert(url.clone(), "\"orphan-etag\"".to_owned());

        Mock::given(method("GET"))
            .and(path("/resource"))
            .and(header("If-None-Match", "\"orphan-etag\""))
            .respond_with(ResponseTemplate::new(304))
            .expect(1)
            .mount(&server)
            .await;

        let result = etag_get(&client, &url, &etags, &bodies).await;
        assert!(
            result.is_none(),
            "304 with empty body cache should return None without panicking"
        );
    }

    // ── 6. First call must NOT send If-None-Match header ─────────────────────

    #[tokio::test]
    async fn etag_get_first_call_does_not_send_if_none_match_header() {
        let server = MockServer::start().await;
        let client = make_client();
        let (etags, bodies) = empty_caches();

        Mock::given(method("GET"))
            .and(path("/no-header"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("etag", "\"first\"")
                    .set_body_string(r#"{"ok":true}"#),
            )
            .mount(&server)
            .await;

        let url = format!("{}/no-header", server.uri());
        let result = etag_get(&client, &url, &etags, &bodies).await;
        assert!(result.is_some());

        let received = server.received_requests().await.unwrap();
        assert_eq!(received.len(), 1);
        assert!(
            !received[0].headers.contains_key("if-none-match"),
            "first call must not send If-None-Match"
        );
    }
}
