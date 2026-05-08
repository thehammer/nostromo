//! Perri PR queue native data source — uses GitHub search API directly.
//!
//! Runs two queries:
//!   1. `is:open is:pr review-requested:@me archived:false`  → `requested = true`
//!   2. `is:open is:pr assignee:@me archived:false`          → `requested = false`
//!
//! Results are deduped by URL.  Each query stores its ETag in memory; on HTTP
//! 304 (Not Modified) the previous snapshot is reused so no unnecessary
//! processing occurs.

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

// ── GitHub search response shape ──────────────────────────────────────────────

#[derive(Deserialize)]
struct SearchResponse {
    items: Vec<SearchIssueItem>,
}

#[derive(Deserialize)]
struct SearchIssueItem {
    number: u64,
    title: String,
    html_url: String,
    repository_url: String,
    user: Option<GhUser>,
}

#[derive(Deserialize)]
struct GhUser {
    login: String,
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

        // ETag cache per query string.
        let mut etags: HashMap<String, String> = HashMap::new();
        // Item cache per query (for 304 reuse).
        let mut item_cache: HashMap<String, Vec<(SearchIssueItem, bool)>> = HashMap::new();

        loop {
            match self.fetch(&client, &mut etags, &mut item_cache).await {
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
        etags: &mut HashMap<String, String>,
        item_cache: &mut HashMap<String, Vec<(SearchIssueItem, bool)>>,
    ) -> Result<PrQueueSnapshot> {
        let queries: &[(&str, bool)] = &[
            ("is:open is:pr review-requested:@me archived:false", true),
            ("is:open is:pr assignee:@me archived:false", false),
        ];

        let mut all_items: Vec<(String, PrQueueItem)> = Vec::new(); // keyed by URL for dedup

        for &(query, requested) in queries {
            let items = search_prs(client, query, requested, etags, item_cache).await?;
            for item in items {
                // Dedup: if URL already present, keep the first occurrence.
                if !all_items.iter().any(|(url, _)| url == &item.url) {
                    all_items.push((item.url.clone(), item));
                }
            }
        }

        Ok(PrQueueSnapshot {
            generated_at: Some(Utc::now()),
            items: all_items.into_iter().map(|(_, it)| it).collect(),
            stale: false,
            error: None,
        })
    }

    fn build_client(&self) -> Result<GithubClient> {
        let hosts_path = self
            .config
            .github_token_path
            .as_deref();
        GithubClient::new(hosts_path)
    }
}

// ── GitHub search request ─────────────────────────────────────────────────────

async fn search_prs(
    client: &GithubClient,
    query: &str,
    requested: bool,
    etags: &mut HashMap<String, String>,
    item_cache: &mut HashMap<String, Vec<(SearchIssueItem, bool)>>,
) -> Result<Vec<PrQueueItem>> {
    let url = format!(
        "https://api.github.com/search/issues?q={}&per_page=50",
        urlencoding::encode(query)
    );

    let mut headers = HeaderMap::new();
    headers.insert(ACCEPT, "application/vnd.github+json".parse().unwrap());
    headers.insert(
        "X-GitHub-Api-Version",
        "2022-11-28".parse().unwrap(),
    );
    headers.insert(
        AUTHORIZATION,
        format!("Bearer {}", client.token()).parse().unwrap(),
    );
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

    // Store fresh ETag.
    if let Some(etag) = resp.headers().get("etag").and_then(|v| v.to_str().ok()) {
        etags.insert(query.to_owned(), etag.to_owned());
    }

    if resp.status() == reqwest::StatusCode::NOT_MODIFIED {
        debug!("github search 304 for query: {query}");
        // Return cached items.
        return Ok(item_cache
            .get(query)
            .map(|cached| build_pr_items(cached))
            .unwrap_or_default());
    }

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("github search -> {status}: {body}");
    }

    let search: SearchResponse = resp.json().await.context("parsing github search response")?;
    let tagged: Vec<(SearchIssueItem, bool)> =
        search.items.into_iter().map(|i| (i, requested)).collect();
    let result = build_pr_items(&tagged);
    item_cache.insert(query.to_owned(), tagged);
    Ok(result)
}

fn build_pr_items(items: &[(SearchIssueItem, bool)]) -> Vec<PrQueueItem> {
    items
        .iter()
        .map(|(item, requested)| {
            // repository_url: "https://api.github.com/repos/{owner}/{repo}"
            let repo = item
                .repository_url
                .trim_start_matches("https://api.github.com/repos/")
                .to_owned();

            PrQueueItem {
                repo,
                number: item.number,
                title: item.title.clone(),
                author: item.user.as_ref().map(|u| u.login.clone()).unwrap_or_default(),
                requested: *requested,
                url: item.html_url.clone(),
            }
        })
        .collect()
}

// ── URL encoding ──────────────────────────────────────────────────────────────
// Use the `url` crate for percent-encoding.

mod urlencoding {
    pub fn encode(s: &str) -> String {
        url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
    }
}
