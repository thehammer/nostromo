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
    pub fn spawn(config: Config) -> watch::Receiver<Option<PrQueueSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.perri_state_dir().join("queue.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        let interval_secs = config.pr_queue_poll_secs;

        tokio::spawn(async move {
            let source = PerriQueueNativeSource { config };
            source.run(tx, &mut dirty_rx, interval_secs).await;
        });

        rx
    }

    async fn run(
        &self,
        tx: watch::Sender<Option<PrQueueSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
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
                .fetch(&client, &me_login, &mut etags, &mut item_cache)
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
                    debug!("perri queue dirty signal");
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
    ) -> Result<PrQueueSnapshot> {
        // ── Run the three search queries ──────────────────────────────────────
        let q_requested =
            "is:open is:pr review-requested:@me org:Carefeed archived:false".to_owned();
        let q_needs =
            "is:open is:pr review:required org:Carefeed archived:false".to_owned();
        let q_reviewed =
            "is:open is:pr reviewed-by:@me org:Carefeed archived:false".to_owned();

        // Searches must run sequentially because they share the mutable ETag
        // and item caches.  This is fine — the poll interval is 60s.
        let requested_items = search_issues(client, &q_requested, etags, item_cache).await?;
        let needs_items = search_issues(client, &q_needs, etags, item_cache).await?;
        let reviewed_items = search_issues(client, &q_reviewed, etags, item_cache).await?;

        // ── Build bucket 1 & 2 candidates (dedup, basic filters) ─────────────
        // requested takes priority; needs_review fills in the rest.
        let requested_urls: std::collections::HashSet<&str> =
            requested_items.iter().map(|i| i.html_url.as_str()).collect();

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
                async move {
                    let repo = repo_from_url(&item.repository_url);
                    if ci_has_failure(&client, &repo, item.number).await {
                        return None;
                    }
                    Some(PrQueueItem {
                        repo,
                        number: item.number,
                        title: item.title.clone(),
                        author: item.user.as_ref().map(|u| u.login.clone()).unwrap_or_default(),
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
                async move {
                    let repo = repo_from_url(&item.repository_url);
                    let (state, submitted_at) =
                        get_our_last_review(&client, &repo, item.number, &me).await?;

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

                    if ci_has_failure(&client, &repo, item.number).await {
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

    let search: SearchResponse = resp.json().await.context("parsing github search response")?;
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
        .filter(|r| r.user.as_ref().map(|u| u.login.as_str()) == Some(me))
        .next_back()
        .map(|r| (r.state, r.submitted_at))
}

/// Returns `true` if any GitHub Actions check suite on the PR's HEAD commit
/// has `conclusion = "failure"`.  On any API error, returns `false` (safe default).
async fn ci_has_failure(client: &GithubClient, repo: &str, number: u64) -> bool {
    let sha = match get_pr_head_sha(client, repo, number).await {
        Some(s) => s,
        None => return false,
    };

    let url = format!("https://api.github.com/repos/{repo}/commits/{sha}/check-suites");
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
    let url = format!("https://api.github.com/repos/{repo}/pulls/{number}");
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
