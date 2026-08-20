//! Perri current-PR native data source.
//!
//! Reads `~/.claude/state/perri/current-pr.json` to find which PR to display,
//! then fetches metadata via `octocrab` and the raw diff via a reqwest GET with
//! `Accept: application/vnd.github.diff`.
//!
//! Phase 4: `PerriPrNativeSource::spawn` now returns a `refresh_tx` alongside
//! the `watch::Receiver`.  Callers (e.g. `perri.load_pr` MCP tool) can send
//! `()` on the sender to trigger an immediate re-fetch without touching the
//! dirty-file sentinel.  The sentinel watcher is kept as a fallback for the
//! deprecation window.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use reqwest::header::{ACCEPT, AUTHORIZATION};
use serde::Deserialize;
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{
    config::Config,
    data::{
        dirty_file,
        github_client::GithubClient,
        perri_pr::{CiCheck, PrComment, PrSnapshot, PrThread, PrThreadKind},
        perri_queue::CiState,
        perri_queue_native::{api_base, etag_get},
    },
};

// ── Large-diff thresholds ─────────────────────────────────────────────────────

const MAX_DIFF_BYTES: usize = 500_000;
const MAX_DIFF_LINES: usize = 2_000;
const MAX_CHANGED_FILES: u64 = 100;

/// Returns `true` when the diff exceeds the render threshold.  Unit-testable
/// free function so thresholds can be verified without network calls.
pub fn diff_is_too_large(diff: &str, changed_files: u64) -> bool {
    changed_files > MAX_CHANGED_FILES
        || diff.len() > MAX_DIFF_BYTES
        || diff.lines().count() > MAX_DIFF_LINES
}

// ── Per-PR cache path ─────────────────────────────────────────────────────────

fn pr_cache_path(state_dir: &Path, repo: &str, number: u64) -> PathBuf {
    // repo is "owner/name"; sanitize the slash so it's one flat filename.
    let safe = repo.replace('/', "-");
    state_dir
        .join("pr-cache")
        .join(format!("{safe}-{number}.json"))
}

/// Write `json` to `path` atomically via a temp-file + rename so a concurrent
/// reader never sees a partial write.
fn write_json_atomic(path: &Path, json: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json)?;
    std::fs::rename(&tmp, path)
}

// ── Pre-fetch entry point (called from perri_queue_native) ────────────────────

/// Fetch the PR detail for `(repo, number)` and write it to the per-PR cache
/// file.  Never reads or writes `current-pr.json`.  Errors are returned so the
/// caller can log them; they do not affect the queue source's cycle.
pub async fn prefetch_into_cache(
    config: &Config,
    client: &GithubClient,
    repo: &str,
    number: u64,
) -> Result<()> {
    let source = PerriPrNativeSource::new(config.clone());
    let snap = source.fetch_pr(client, repo, number).await?;
    let json = serde_json::to_string(&snap).context("serializing prefetch snapshot")?;
    let cache = pr_cache_path(&config.perri_state_dir(), repo, number);
    write_json_atomic(&cache, &json).context("writing prefetch cache file")?;
    debug!(
        "perri prefetch {repo}#{number} cached at {}",
        cache.display()
    );
    Ok(())
}

// ── Check-runs API response shapes ───────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct CheckRunsResponse {
    check_runs: Vec<PrCheckRun>,
}

#[derive(Debug, Deserialize)]
struct PrCheckRun {
    name: String,
    status: Option<String>,
    conclusion: Option<String>,
    id: Option<u64>,
    app: Option<PrCheckRunApp>,
    output: Option<PrCheckRunOutput>,
}

#[derive(Debug, Deserialize)]
struct PrCheckRunApp {
    slug: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
struct PrCheckRunOutput {
    title: Option<String>,
    summary: Option<String>,
    text: Option<String>,
}

// ── current-pr.json shape ─────────────────────────────────────────────────────

/// Matches the format written by `perri-diff-pane` and the real Perri state.
#[derive(Debug, Deserialize)]
pub struct CurrentPrPointer {
    pub number: u64,
    pub repo: String, // "owner/repo"
    pub title: Option<String>,
    pub author: Option<String>,
    pub url: Option<String>,
}

// ── Source ────────────────────────────────────────────────────────────────────

pub struct PerriPrNativeSource {
    config: Config,
    /// ETag caches for the conversation fetches (W3 — curated-agent-views),
    /// so a refetch against unchanged data costs one 304 instead of a full
    /// GitHub response. `Arc`-shared rather than owned so every construction
    /// site (`spawn`, `prefetch_into_cache`, `fetch_for_cache`) can hand out a
    /// cheap clone; only the long-lived instance `spawn` keeps alive across
    /// polling cycles actually benefits from cache hits, and a fresh one-shot
    /// instance simply starts cold (a full fetch, no correctness issue).
    conversation_etags: Arc<Mutex<HashMap<String, String>>>,
    conversation_body_cache: Arc<Mutex<HashMap<String, String>>>,
}

impl PerriPrNativeSource {
    /// Build a source instance with fresh, empty conversation caches.
    fn new(config: Config) -> Self {
        PerriPrNativeSource {
            config,
            conversation_etags: Arc::new(Mutex::new(HashMap::new())),
            conversation_body_cache: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Spawn the data source.
    ///
    /// Returns `(snapshot_rx, refresh_tx)`.
    ///
    /// - `snapshot_rx` — watch receiver for the latest `PrSnapshot`.
    /// - `refresh_tx`  — send `()` to trigger an immediate re-fetch (direct
    ///   MCP push path introduced in Phase 4).  The dirty-file watcher remains
    ///   active as a fallback for the shell-script deprecation window.
    pub fn spawn(
        config: Config,
    ) -> (
        watch::Receiver<Option<PrSnapshot>>,
        mpsc::UnboundedSender<()>,
    ) {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();
        let (refresh_tx, mut refresh_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.perri_state_dir().join("current-pr.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        let interval_secs = config.pr_diff_poll_secs;

        tokio::spawn(async move {
            let source = PerriPrNativeSource::new(config);
            source
                .run(tx, &mut dirty_rx, &mut refresh_rx, interval_secs)
                .await;
        });

        (rx, refresh_tx)
    }

    async fn run(
        &self,
        tx: watch::Sender<Option<PrSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
        refresh_rx: &mut mpsc::UnboundedReceiver<()>,
        interval_secs: u64,
    ) {
        let client = match self.build_client() {
            Ok(c) => c,
            Err(e) => {
                warn!("github client init failed for perri pr: {e:#}");
                let _ = tx.send(Some(PrSnapshot {
                    error: Some(format!("GitHub client init failed: {e:#}")),
                    stale: true,
                    ..Default::default()
                }));
                return;
            }
        };

        loop {
            match self.fetch(&client).await {
                Ok(snap) => {
                    debug!(pr = ?snap.pr_number, "perri diff refreshed");
                    let _ = tx.send(Some(snap));
                }
                Err(e) => {
                    warn!("perri diff fetch failed: {e:#}");
                    let mut snap = tx.borrow().clone().unwrap_or_default();
                    snap.stale = true;
                    snap.error = Some(e.to_string());
                    let _ = tx.send(Some(snap));
                }
            }

            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_secs(interval_secs)) => {}
                // `Some(_) = recv()` disables the branch on a closed channel.
                // The plain `_ =` form matches None and fires every poll once
                // the sender is dropped, producing a hot loop.
                Some(_) = dirty_rx.recv() => {
                    debug!("perri diff dirty-file signal");
                }
                Some(_) = refresh_rx.recv() => {
                    debug!("perri diff direct-push refresh signal (MCP)");
                }
            }

            // A caller (e.g. `perri.load_pr`) may touch the dirty sentinel
            // *and* send on `refresh_tx` for the same logical change — drain
            // whichever channel(s) didn't win the select above so a single
            // change collapses into exactly one fetch cycle instead of two.
            while dirty_rx.try_recv().is_ok() {}
            while refresh_rx.try_recv().is_ok() {}
        }
    }

    /// Main fetch: reads `current-pr.json`, fetches the PR, writes BOTH
    /// `current-pr-detail.json` and the per-PR cache file.
    async fn fetch(&self, client: &GithubClient) -> Result<PrSnapshot> {
        let pointer_path = self.current_pr_path();

        if !pointer_path.exists() {
            return Ok(PrSnapshot {
                title: "(no PR loaded)".to_owned(),
                ..Default::default()
            });
        }

        let raw = tokio::fs::read_to_string(&pointer_path)
            .await
            .with_context(|| format!("reading {}", pointer_path.display()))?;

        let pointer: CurrentPrPointer =
            serde_json::from_str(&raw).context("parsing current-pr.json")?;

        let snap = self.fetch_pr(client, &pointer.repo, pointer.number).await?;

        // Write both files; log and swallow errors (the watch channel still feeds the TUI).
        let state_dir = self.config.perri_state_dir();
        match serde_json::to_string(&snap) {
            Ok(json) => {
                // Single-slot selected-PR file.
                let detail_path = state_dir.join("current-pr-detail.json");
                if let Err(e) = write_json_atomic(&detail_path, &json) {
                    warn!("perri detail write (current-pr-detail.json) failed: {e:#}");
                }
                // Per-PR cache file.
                let cache = pr_cache_path(&state_dir, &pointer.repo, pointer.number);
                if let Err(e) = write_json_atomic(&cache, &json) {
                    warn!("perri detail write (pr-cache) failed: {e:#}");
                }
            }
            Err(e) => warn!("perri detail serialize failed: {e:#}"),
        }

        Ok(snap)
    }

    /// Fetch `(repo, number)` via GitHub API and return a `PrSnapshot`.
    /// Does NOT read or write any files — all I/O is the caller's responsibility.
    async fn fetch_pr(&self, client: &GithubClient, repo: &str, number: u64) -> Result<PrSnapshot> {
        let (owner, repo_name) = split_repo(repo)?;

        // Fetch PR metadata via octocrab for authoritative fields.
        let pr_meta = client
            .octocrab
            .pulls(&owner, &repo_name)
            .get(number)
            .await
            .with_context(|| format!("fetching PR {owner}/{repo_name} #{number}"))?;

        let title = pr_meta.title.clone().unwrap_or_default();
        let author = pr_meta
            .user
            .as_ref()
            .map(|u| u.login.clone())
            .unwrap_or_default();
        let url = pr_meta
            .html_url
            .as_ref()
            .map(|u| u.to_string())
            .unwrap_or_default();

        // D5: size fields from pr_meta (octocrab PullRequest exposes these).
        let additions = pr_meta.additions.unwrap_or(0);
        let deletions = pr_meta.deletions.unwrap_or(0);
        let changed_files = pr_meta.changed_files.unwrap_or(0);
        let head_sha = pr_meta.head.sha.clone();

        // Fetch the raw diff.
        let raw_diff = fetch_diff(client, &owner, &repo_name, number).await?;

        // Apply large-diff threshold: blank the diff and set the flag.
        let (diff, diff_too_large) = if diff_is_too_large(&raw_diff, changed_files) {
            (String::new(), true)
        } else {
            (raw_diff, false)
        };

        // D2/D3: fetch check-runs for the PR head SHA and build CiCheck list.
        let ci_checks = fetch_ci_checks(client, &owner, &repo_name, &head_sha).await;

        // W3 — curated-agent-views: the PR description, plus its comment and
        // review threads. A conversation-fetch failure must not fail the
        // whole `PrSnapshot` — the PR data (diff, CI, description) is already
        // in hand and stays useful even if the threads didn't load.
        let body = pr_meta.body.clone().unwrap_or_default();
        let conversation = self
            .fetch_conversation(client, &owner, &repo_name, number)
            .await;

        Ok(PrSnapshot {
            pr_number: Some(number),
            repo: repo.to_owned(),
            title,
            author,
            url,
            diff,
            diff_too_large,
            stale: false,
            error: None,
            generated_at: Some(chrono::Utc::now()),
            ci_checks,
            additions,
            deletions,
            changed_files,
            head_sha,
            body,
            threads: conversation.threads,
            conversation_error: conversation.error,
        })
    }

    /// Fetch the PR's comment/review threads (W3 — curated-agent-views): the
    /// three REST calls in D3, conditional-GET'd against this instance's
    /// caches, assembled into [`PrThread`]s. Never fails outright — a failed
    /// individual call is recorded in [`ConversationFetch::error`] and simply
    /// contributes nothing to `threads`, so the caller always gets whatever
    /// could be retrieved rather than nothing at all.
    async fn fetch_conversation(
        &self,
        client: &GithubClient,
        owner: &str,
        repo: &str,
        number: u64,
    ) -> ConversationFetch {
        let issue_comments = fetch_issue_comments(
            client,
            owner,
            repo,
            number,
            &self.conversation_etags,
            &self.conversation_body_cache,
        )
        .await;
        let review_comments = fetch_review_comments(
            client,
            owner,
            repo,
            number,
            &self.conversation_etags,
            &self.conversation_body_cache,
        )
        .await;
        let reviews = fetch_reviews(
            client,
            owner,
            repo,
            number,
            &self.conversation_etags,
            &self.conversation_body_cache,
        )
        .await;

        let mut failed: Vec<&str> = Vec::new();
        if issue_comments.is_none() {
            failed.push("issue comments");
        }
        if review_comments.is_none() {
            failed.push("review comments");
        }
        if reviews.is_none() {
            failed.push("reviews");
        }

        let threads = assemble_threads(
            issue_comments.unwrap_or_default(),
            review_comments.unwrap_or_default(),
            reviews.unwrap_or_default(),
        );

        let error = if failed.is_empty() {
            None
        } else {
            Some(format!(
                "conversation fetch partially failed: {}",
                failed.join(", ")
            ))
        };

        ConversationFetch { threads, error }
    }

    /// Fetch for cache only: fetches the PR and writes the per-PR cache file.
    /// Never reads or writes `current-pr.json` or `current-pr-detail.json`.
    pub async fn fetch_for_cache(
        &self,
        client: &GithubClient,
        repo: &str,
        number: u64,
    ) -> Result<()> {
        let snap = self.fetch_pr(client, repo, number).await?;
        let json = serde_json::to_string(&snap).context("serializing snapshot for cache")?;
        let cache = pr_cache_path(&self.config.perri_state_dir(), repo, number);
        write_json_atomic(&cache, &json).context("writing per-PR cache file")?;
        debug!("perri pr cache written: {}", cache.display());
        Ok(())
    }

    fn current_pr_path(&self) -> PathBuf {
        self.config.perri_state_dir().join("current-pr.json")
    }

    fn build_client(&self) -> Result<GithubClient> {
        GithubClient::new(self.config.github_token_path.as_deref())
    }
}

// ── Raw diff fetch ────────────────────────────────────────────────────────────

async fn fetch_diff(client: &GithubClient, owner: &str, repo: &str, number: u64) -> Result<String> {
    let url = format!("https://api.github.com/repos/{owner}/{repo}/pulls/{number}");

    let resp = client
        .http
        .get(&url)
        .header(ACCEPT, "application/vnd.github.diff")
        .header(AUTHORIZATION, format!("Bearer {}", client.token()))
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .await
        .context("fetching PR diff")?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("diff fetch {url} -> {status}: {body}");
    }

    resp.text().await.context("reading diff body")
}

// ── CI check-runs fetch ───────────────────────────────────────────────────────

/// Fetch check-runs for the PR head SHA and build the `CiCheck` list.
/// On any error, logs a warning and returns an empty vec (diff is primary).
async fn fetch_ci_checks(
    client: &GithubClient,
    owner: &str,
    repo: &str,
    head_sha: &str,
) -> Vec<CiCheck> {
    let url = format!(
        "https://api.github.com/repos/{owner}/{repo}/commits/{head_sha}/check-runs?per_page=100"
    );

    let resp = client
        .http
        .get(&url)
        .header(ACCEPT, "application/vnd.github+json")
        .header(AUTHORIZATION, format!("Bearer {}", client.token()))
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .await;

    let resp = match resp {
        Ok(r) => r,
        Err(e) => {
            warn!("check-runs fetch failed: {e:#}");
            return vec![];
        }
    };

    if !resp.status().is_success() {
        warn!("check-runs fetch non-2xx: {}", resp.status());
        return vec![];
    }

    let body: CheckRunsResponse = match resp.json().await {
        Ok(b) => b,
        Err(e) => {
            warn!("check-runs parse failed: {e:#}");
            return vec![];
        }
    };

    let mut checks = Vec::with_capacity(body.check_runs.len());
    for run in body.check_runs {
        let state = CiState::from_check(run.status.as_deref(), run.conclusion.as_deref());
        let detail = if state == CiState::Failure {
            Some(fetch_failure_detail(client, owner, repo, &run).await)
        } else {
            None
        };
        checks.push(CiCheck {
            name: run.name,
            state,
            detail,
        });
    }
    checks
}

/// Fetch the failure log for a failing check-run (D3).
/// For GitHub Actions runs, gets the job log tail (last 50 lines).
/// For others (or on failure), falls back to output text/summary/title.
async fn fetch_failure_detail(
    client: &GithubClient,
    owner: &str,
    repo: &str,
    run: &PrCheckRun,
) -> String {
    let is_actions = run.app.as_ref().and_then(|a| a.slug.as_deref()) == Some("github-actions");

    if is_actions {
        if let Some(id) = run.id {
            let log_url =
                format!("https://api.github.com/repos/{owner}/{repo}/actions/jobs/{id}/logs");
            let resp = client
                .http
                .get(&log_url)
                .header(ACCEPT, "application/vnd.github+json")
                .header(AUTHORIZATION, format!("Bearer {}", client.token()))
                .header("X-GitHub-Api-Version", "2022-11-28")
                .send()
                .await;

            if let Ok(r) = resp {
                if r.status().is_success() {
                    if let Ok(text) = r.text().await {
                        if !text.is_empty() {
                            return truncate_tail(&text, 50);
                        }
                    }
                }
            }
        }
    }

    // Fallback: use output fields (head, since they're short).
    let text = run
        .output
        .as_ref()
        .and_then(|o| o.text.as_deref().filter(|s| !s.is_empty()))
        .or_else(|| {
            run.output
                .as_ref()
                .and_then(|o| o.summary.as_deref().filter(|s| !s.is_empty()))
        })
        .or_else(|| {
            run.output
                .as_ref()
                .and_then(|o| o.title.as_deref().filter(|s| !s.is_empty()))
        })
        .unwrap_or("");

    truncate_tail(text, 50)
}

/// Take the last `max_lines` lines of `text`, indent each by 4 spaces,
/// and append a truncation marker when lines are dropped.
fn truncate_tail(text: &str, max_lines: usize) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let total = lines.len();
    let (start, dropped) = if total > max_lines {
        (total - max_lines, total - max_lines)
    } else {
        (0, 0)
    };

    let mut out = String::new();
    for line in &lines[start..] {
        out.push_str("    ");
        out.push_str(line);
        out.push('\n');
    }
    if dropped > 0 {
        out.push_str(&format!("    … (truncated, {dropped} more lines)\n"));
    }
    out
}

// ── PR conversation (W3 — curated-agent-views) ───────────────────────────────

/// The result of [`PerriPrNativeSource::fetch_conversation`]: whatever threads
/// could be assembled, plus a human-readable note when one or more of the
/// three underlying fetches failed. `error.is_some()` never means `threads`
/// is empty by construction — a review-comments failure alongside a
/// successful issue-comments fetch still yields issue threads.
struct ConversationFetch {
    threads: Vec<PrThread>,
    error: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
struct RawGhUser {
    login: String,
}

/// `GET /repos/{o}/{r}/issues/{n}/comments` — top-level PR conversation
/// comments (GitHub calls a PR's issue-comments endpoint the same one issues
/// use).
#[derive(Debug, Deserialize, Clone)]
struct RawIssueComment {
    id: u64,
    user: Option<RawGhUser>,
    created_at: chrono::DateTime<chrono::Utc>,
    body: Option<String>,
}

/// `GET /repos/{o}/{r}/pulls/{n}/comments` — inline review comments.
#[derive(Debug, Deserialize, Clone)]
struct RawReviewComment {
    id: u64,
    #[serde(default)]
    in_reply_to_id: Option<u64>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    line: Option<u32>,
    #[serde(default)]
    original_line: Option<u32>,
    #[serde(default)]
    diff_hunk: Option<String>,
    user: Option<RawGhUser>,
    created_at: chrono::DateTime<chrono::Utc>,
    body: Option<String>,
}

/// `GET /repos/{o}/{r}/pulls/{n}/reviews` — whole-PR reviews.
#[derive(Debug, Deserialize, Clone)]
struct RawReview {
    id: u64,
    user: Option<RawGhUser>,
    #[serde(default)]
    submitted_at: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(default)]
    body: Option<String>,
    /// `"PENDING"`, `"APPROVED"`, `"CHANGES_REQUESTED"`, `"COMMENTED"`,
    /// `"DISMISSED"`. This endpoint includes the *authenticated user's own*
    /// unsubmitted draft review, whose `submitted_at` is `null` — that's the
    /// signal `assemble_threads` uses to exclude it, since a draft has
    /// nothing an operator can act on yet.
    #[serde(default)]
    state: String,
}

/// Conditional-GET one paginated conversation endpoint and deserialize its
/// body as a list of `T`. The three D3 fetches (`fetch_issue_comments`,
/// `fetch_review_comments`, `fetch_reviews`) differ only in `path` and the
/// element type they deserialize into, so this is the one place that shape
/// is spelled: a failed `etag_get` (network error, non-2xx/304) or a body
/// that doesn't parse as `Vec<T>` both collapse to `None`, which
/// `fetch_conversation` already treats as "this endpoint failed".
async fn fetch_conversation_page<T: serde::de::DeserializeOwned>(
    client: &GithubClient,
    path: &str,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<Vec<T>> {
    let url = format!("{}{path}", api_base());
    let body = etag_get(client, &url, etags, body_cache).await?;
    serde_json::from_str(&body).ok()
}

async fn fetch_issue_comments(
    client: &GithubClient,
    owner: &str,
    repo: &str,
    number: u64,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<Vec<RawIssueComment>> {
    let path = format!("/repos/{owner}/{repo}/issues/{number}/comments?per_page=100");
    fetch_conversation_page(client, &path, etags, body_cache).await
}

async fn fetch_review_comments(
    client: &GithubClient,
    owner: &str,
    repo: &str,
    number: u64,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<Vec<RawReviewComment>> {
    let path = format!("/repos/{owner}/{repo}/pulls/{number}/comments?per_page=100");
    fetch_conversation_page(client, &path, etags, body_cache).await
}

async fn fetch_reviews(
    client: &GithubClient,
    owner: &str,
    repo: &str,
    number: u64,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<Vec<RawReview>> {
    let path = format!("/repos/{owner}/{repo}/pulls/{number}/reviews?per_page=100");
    fetch_conversation_page(client, &path, etags, body_cache).await
}

/// Assemble the three raw GitHub payloads into [`PrThread`]s (D3). Pure and
/// synchronous, so the tricky part — walking `in_reply_to_id` to a root and
/// never dropping an orphaned reply — is unit-testable with no network.
///
/// - Each issue comment becomes its own single-comment `Issue` thread.
/// - Each review with a non-empty body becomes its own single-comment
///   `Review` thread; a review with no body (an approval/request-changes with
///   nothing written) is not a thread — there is nothing to show.
/// - Review comments are grouped by walking `in_reply_to_id` to its root. A
///   comment whose stated parent is not present in this payload becomes a
///   root of its own (its own thread) rather than being dropped.
fn assemble_threads(
    issue_comments: Vec<RawIssueComment>,
    review_comments: Vec<RawReviewComment>,
    reviews: Vec<RawReview>,
) -> Vec<PrThread> {
    let mut threads = Vec::new();

    for c in issue_comments {
        threads.push(PrThread {
            id: format!("issue-{}", c.id),
            kind: PrThreadKind::Issue,
            path: None,
            line: None,
            diff_hunk: None,
            resolved: false,
            comments: vec![PrComment {
                id: c.id.to_string(),
                author: c.user.map(|u| u.login).unwrap_or_default(),
                created_at: c.created_at,
                body: c.body.unwrap_or_default(),
            }],
        });
    }

    for r in reviews {
        // A PENDING review is the authenticated user's own unsubmitted
        // draft — it has no submitted_at (GitHub returns null), and showing
        // it as if it were a real, submitted review would be actively
        // misleading: there's no submission to react to yet, and its
        // presence/absence would toggle on every refetch since a draft can
        // be edited or discarded at any time with no PR-level event. Skip it
        // rather than fabricating a timestamp for it.
        if r.state == "PENDING" {
            continue;
        }
        let Some(body) = r.body.filter(|b| !b.trim().is_empty()) else {
            continue;
        };
        let Some(created_at) = r.submitted_at else {
            // Not PENDING but still no submitted_at — an unexpected shape
            // from GitHub, not the known draft case. Skip rather than
            // synthesize a timestamp that would churn the cache/broadcast on
            // every refetch even though nothing about the review changed.
            continue;
        };
        threads.push(PrThread {
            id: format!("review-{}", r.id),
            kind: PrThreadKind::Review,
            path: None,
            line: None,
            diff_hunk: None,
            resolved: false,
            comments: vec![PrComment {
                id: r.id.to_string(),
                author: r.user.map(|u| u.login).unwrap_or_default(),
                created_at,
                body,
            }],
        });
    }

    threads.extend(assemble_inline_threads(review_comments));
    threads
}

/// The inline-review-comment half of [`assemble_threads`], split out because
/// the root-resolution walk is the one genuinely tricky piece of this file.
fn assemble_inline_threads(review_comments: Vec<RawReviewComment>) -> Vec<PrThread> {
    let by_id: HashMap<u64, &RawReviewComment> =
        review_comments.iter().map(|c| (c.id, c)).collect();

    /// Walk `in_reply_to_id` up to its root. A parent id that isn't present
    /// in `by_id` (the common real-world case: the root predates this fetch's
    /// page, or was filtered out upstream) makes `comment` itself the root —
    /// "never dropped" rather than silently vanishing. A cycle (shouldn't
    /// happen on real GitHub data, but a malformed payload could produce one)
    /// is broken the same way: the first id seen twice becomes the root.
    fn root_id(comment: &RawReviewComment, by_id: &HashMap<u64, &RawReviewComment>) -> u64 {
        let mut current = comment;
        let mut seen = std::collections::HashSet::new();
        loop {
            seen.insert(current.id);
            let Some(parent_id) = current.in_reply_to_id else {
                return current.id;
            };
            if seen.contains(&parent_id) {
                return current.id;
            }
            match by_id.get(&parent_id) {
                Some(parent) => current = parent,
                None => return current.id,
            }
        }
    }

    let mut order: Vec<u64> = Vec::new();
    let mut grouped: HashMap<u64, Vec<&RawReviewComment>> = HashMap::new();
    for c in &review_comments {
        let root = root_id(c, &by_id);
        grouped.entry(root).or_insert_with(|| {
            order.push(root);
            Vec::new()
        });
        grouped.get_mut(&root).unwrap().push(c);
    }

    let mut threads = Vec::with_capacity(order.len());
    for root in order {
        let mut comments = grouped.remove(&root).unwrap_or_default();
        // Chronological, tie-broken by id so ordering is stable across
        // refetches even when two comments share a timestamp.
        comments.sort_by_key(|c| (c.created_at, c.id));

        let anchor = comments
            .iter()
            .find(|c| c.id == root)
            .or_else(|| comments.first());
        let (path, line, diff_hunk) = anchor
            .map(|c| (c.path.clone(), c.line.or(c.original_line), c.diff_hunk.clone()))
            .unwrap_or((None, None, None));

        threads.push(PrThread {
            id: format!("inline-{root}"),
            kind: PrThreadKind::Inline,
            path,
            line,
            diff_hunk,
            resolved: false,
            comments: comments
                .into_iter()
                .map(|c| PrComment {
                    id: c.id.to_string(),
                    author: c.user.clone().map(|u| u.login).unwrap_or_default(),
                    created_at: c.created_at,
                    body: c.body.clone().unwrap_or_default(),
                })
                .collect(),
        });
    }
    threads
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn split_repo(repo: &str) -> Result<(String, String)> {
    let mut parts = repo.splitn(2, '/');
    let owner = parts
        .next()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow::anyhow!("invalid repo format: {repo}"))?;
    let name = parts
        .next()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow::anyhow!("invalid repo format: {repo}"))?;
    Ok((owner.to_owned(), name.to_owned()))
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Regression guard for the double-wake coalescing fix (D6).
    ///
    /// `perri.load_pr` writes `current-pr.json`, touches `current-pr.dirty`
    /// *and* signals `refresh_tx` for the same logical change. Without the
    /// post-select drain, that produces two pending wakes and two fetch
    /// cycles (and two GitHub calls) for one change. This exercises the
    /// exact `select!` + drain shape used in `run()`, without touching the
    /// network: it queues both signals, confirms the first select cycle
    /// fires immediately, drains the leftover signal, then asserts a second
    /// select waits the full interval — proving no extra cycle followed.
    #[tokio::test]
    async fn coalesces_dirty_and_refresh_signals_into_one_wake() {
        use std::time::Duration;
        use tokio::sync::mpsc;

        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();
        let (refresh_tx, mut refresh_rx) = mpsc::unbounded_channel::<()>();

        // Simulate the double-wake: both signals pending for one change.
        dirty_tx.send(()).unwrap();
        refresh_tx.send(()).unwrap();

        let interval = Duration::from_millis(200);

        // First cycle: one of the two branches fires immediately.
        tokio::select! {
            _ = tokio::time::sleep(interval) => panic!("select should fire immediately with signals pending"),
            Some(_) = dirty_rx.recv() => {}
            Some(_) = refresh_rx.recv() => {}
        }
        // The fix: drain whichever channel didn't win, so the leftover
        // signal doesn't cause a second cycle.
        while dirty_rx.try_recv().is_ok() {}
        while refresh_rx.try_recv().is_ok() {}

        // Second cycle: both channels drained — the select must wait the
        // full interval, proving the leftover signal did not fire a second
        // fetch.
        let start = std::time::Instant::now();
        tokio::select! {
            _ = tokio::time::sleep(interval) => {}
            Some(_) = dirty_rx.recv() => panic!("dirty branch fired after drain — coalescing failed"),
            Some(_) = refresh_rx.recv() => panic!("refresh branch fired after drain — coalescing failed"),
        }
        assert!(
            start.elapsed() >= Duration::from_millis(150),
            "select returned early — a leftover signal was not drained"
        );

        drop(dirty_tx);
        drop(refresh_tx);
    }

    // ── diff_is_too_large ──────────────────────────────────────────────────────

    #[test]
    fn diff_not_too_large_below_all_thresholds() {
        // 99 files, 1_000 lines, 100 bytes — all below threshold.
        let diff = "a\n".repeat(1_000);
        assert!(!diff_is_too_large(&diff, 99));
    }

    #[test]
    fn diff_too_large_by_changed_files() {
        let diff = "a\n".repeat(10);
        assert!(diff_is_too_large(&diff, 101));
    }

    #[test]
    fn diff_too_large_at_exactly_101_files() {
        let diff = "short diff";
        assert!(diff_is_too_large(diff, 101));
    }

    #[test]
    fn diff_not_too_large_at_exactly_100_files() {
        let diff = "short diff";
        assert!(!diff_is_too_large(diff, 100));
    }

    #[test]
    fn diff_too_large_by_byte_count() {
        // 500_001 bytes, 1 line, 0 files changed — bytes threshold triggers.
        let diff = "x".repeat(500_001);
        assert!(diff_is_too_large(&diff, 0));
    }

    #[test]
    fn diff_not_too_large_at_exactly_500_000_bytes() {
        let diff = "x".repeat(500_000);
        assert!(!diff_is_too_large(&diff, 0));
    }

    #[test]
    fn diff_too_large_by_line_count() {
        // 2_001 lines, few bytes, 0 files — line threshold triggers.
        let diff = "a\n".repeat(2_001);
        assert!(diff_is_too_large(&diff, 0));
    }

    #[test]
    fn diff_not_too_large_at_exactly_2000_lines() {
        let diff = "a\n".repeat(2_000);
        assert!(!diff_is_too_large(&diff, 0));
    }

    // ── assemble_threads (W3 — curated-agent-views) ──────────────────────────

    fn issue_comment(id: u64, author: &str, created_at: &str, body: &str) -> RawIssueComment {
        RawIssueComment {
            id,
            user: Some(RawGhUser { login: author.to_string() }),
            created_at: created_at.parse().unwrap(),
            body: Some(body.to_string()),
        }
    }

    fn review(id: u64, author: &str, submitted_at: Option<&str>, body: Option<&str>) -> RawReview {
        RawReview {
            id,
            user: Some(RawGhUser { login: author.to_string() }),
            submitted_at: submitted_at.map(|s| s.parse().unwrap()),
            body: body.map(str::to_string),
            state: "APPROVED".to_string(),
        }
    }

    /// A PENDING (unsubmitted draft) review — no submitted_at, by construction.
    fn pending_review(id: u64, author: &str, body: Option<&str>) -> RawReview {
        RawReview {
            id,
            user: Some(RawGhUser { login: author.to_string() }),
            submitted_at: None,
            body: body.map(str::to_string),
            state: "PENDING".to_string(),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn review_comment(
        id: u64,
        in_reply_to_id: Option<u64>,
        path: Option<&str>,
        line: Option<u32>,
        original_line: Option<u32>,
        diff_hunk: Option<&str>,
        author: &str,
        created_at: &str,
    ) -> RawReviewComment {
        RawReviewComment {
            id,
            in_reply_to_id,
            path: path.map(str::to_string),
            line,
            original_line,
            diff_hunk: diff_hunk.map(str::to_string),
            user: Some(RawGhUser { login: author.to_string() }),
            created_at: created_at.parse().unwrap(),
            body: Some(format!("comment {id}")),
        }
    }

    #[test]
    fn an_issue_comment_becomes_its_own_single_comment_issue_thread() {
        let threads = assemble_threads(
            vec![issue_comment(1, "alice", "2024-01-01T00:00:00Z", "hello")],
            vec![],
            vec![],
        );
        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0].id, "issue-1");
        assert_eq!(threads[0].kind, PrThreadKind::Issue);
        assert_eq!(threads[0].comments.len(), 1);
        assert_eq!(threads[0].comments[0].author, "alice");
        assert_eq!(threads[0].comments[0].body, "hello");
    }

    #[test]
    fn a_review_with_a_non_empty_body_becomes_its_own_review_thread() {
        let threads = assemble_threads(
            vec![],
            vec![],
            vec![review(1, "bob", Some("2024-01-01T00:00:00Z"), Some("looks good"))],
        );
        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0].id, "review-1");
        assert_eq!(threads[0].kind, PrThreadKind::Review);
        assert_eq!(threads[0].comments[0].body, "looks good");
    }

    #[test]
    fn a_pending_draft_review_produces_no_thread_and_no_fabricated_timestamp() {
        // Regression test: `/pulls/{n}/reviews` includes the authenticated
        // user's own PENDING (unsubmitted) draft review, whose submitted_at
        // is null. This used to synthesize `chrono::Utc::now()` for it,
        // producing a thread that looked submitted and whose timestamp
        // changed on every single refetch even though nothing about the
        // review itself had changed.
        let threads = assemble_threads(
            vec![],
            vec![],
            vec![
                pending_review(1, "bob", Some("still drafting this")),
                review(2, "alice", Some("2024-01-01T00:00:00Z"), Some("looks good")),
            ],
        );
        assert_eq!(
            threads.len(),
            1,
            "the pending draft must not produce a thread at all: {threads:?}"
        );
        assert_eq!(
            threads[0].id, "review-2",
            "only the real, submitted review should produce a thread"
        );
    }

    #[test]
    fn a_review_with_an_empty_or_whitespace_only_body_produces_no_thread_at_all() {
        let threads = assemble_threads(
            vec![],
            vec![],
            vec![
                review(1, "bob", Some("2024-01-01T00:00:00Z"), Some("")),
                review(2, "bob", Some("2024-01-01T00:00:00Z"), Some("   \n\t ")),
                review(3, "bob", Some("2024-01-01T00:00:00Z"), None),
            ],
        );
        assert!(
            threads.is_empty(),
            "an empty/whitespace/absent review body must produce no thread, got: {threads:?}"
        );
    }

    #[test]
    fn a_straightforward_reply_chain_groups_into_one_thread_rooted_at_the_top_level_comment() {
        // A (top-level) at 10:00, B (reply to A) at 10:05.
        let a = review_comment(1, None, Some("src/main.rs"), Some(10), None, Some("@@ hunk @@"), "alice", "2024-01-01T10:00:00Z");
        let b = review_comment(2, Some(1), None, None, None, None, "bob", "2024-01-01T10:05:00Z");
        let threads = assemble_inline_threads(vec![a, b]);
        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0].id, "inline-1");
        assert_eq!(threads[0].kind, PrThreadKind::Inline);
        assert_eq!(threads[0].comments.len(), 2);
        // Chronological.
        assert_eq!(threads[0].comments[0].author, "alice");
        assert_eq!(threads[0].comments[1].author, "bob");
    }

    #[test]
    fn a_reply_whose_in_reply_to_id_is_not_present_in_the_payload_becomes_its_own_thread_never_dropped()
    {
        // The highest-risk case per the plan: comment 99 replies to comment 1,
        // but comment 1 was never fetched (predates this page, or was
        // filtered out upstream). Comment 99 must become its own thread's
        // root — not be silently dropped.
        let orphan = review_comment(99, Some(1), Some("src/main.rs"), Some(20), None, Some("@@ hunk @@"), "carol", "2024-01-01T11:00:00Z");
        let threads = assemble_inline_threads(vec![orphan]);
        assert_eq!(
            threads.len(),
            1,
            "an orphaned reply must start its own thread, not vanish"
        );
        assert_eq!(threads[0].id, "inline-99");
        assert_eq!(threads[0].comments.len(), 1);
        assert_eq!(threads[0].comments[0].id, "99");
    }

    #[test]
    fn two_independent_orphans_pointing_at_the_same_missing_parent_become_two_separate_threads() {
        let orphan_a = review_comment(101, Some(5), Some("src/a.rs"), Some(1), None, None, "alice", "2024-01-01T10:00:00Z");
        let orphan_b = review_comment(102, Some(5), Some("src/b.rs"), Some(2), None, None, "bob", "2024-01-01T10:01:00Z");
        let threads = assemble_inline_threads(vec![orphan_a, orphan_b]);
        assert_eq!(
            threads.len(),
            2,
            "two orphans naming the same missing parent must not be merged into one thread, got: {threads:?}"
        );
        let ids: std::collections::HashSet<&str> = threads.iter().map(|t| t.id.as_str()).collect();
        assert!(ids.contains("inline-101"));
        assert!(ids.contains("inline-102"));
        for t in &threads {
            assert_eq!(t.comments.len(), 1, "each orphan's thread carries only itself");
        }
    }

    #[test]
    fn a_threads_path_line_and_diff_hunk_come_from_the_root_comment() {
        let root = review_comment(1, None, Some("src/main.rs"), Some(10), None, Some("@@ -1,3 +1,3 @@"), "alice", "2024-01-01T10:00:00Z");
        let reply = review_comment(2, Some(1), None, None, None, None, "bob", "2024-01-01T10:05:00Z");
        let threads = assemble_inline_threads(vec![root, reply]);
        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0].path.as_deref(), Some("src/main.rs"));
        assert_eq!(threads[0].line, Some(10));
        assert_eq!(threads[0].diff_hunk.as_deref(), Some("@@ -1,3 +1,3 @@"));
    }

    #[test]
    fn a_threads_line_falls_back_to_original_line_when_line_is_null() {
        // Matches a GitHub "outdated" inline comment: `line` is null once the
        // diff has moved on, but `original_line` still names where the
        // comment was anchored.
        let root = review_comment(1, None, Some("src/main.rs"), None, Some(7), Some("@@ hunk @@"), "alice", "2024-01-01T10:00:00Z");
        let threads = assemble_inline_threads(vec![root]);
        assert_eq!(threads.len(), 1);
        assert_eq!(
            threads[0].line,
            Some(7),
            "an outdated comment's line must fall back to original_line"
        );
    }

    #[test]
    fn comment_ordering_within_a_thread_is_chronological_and_tie_broken_by_id_deterministically() {
        // b and c share an identical timestamp; only id order can break the tie.
        let a = review_comment(1, None, Some("f.rs"), Some(1), None, None, "alice", "2024-01-01T10:00:00Z");
        let c = review_comment(3, Some(1), None, None, None, None, "carol", "2024-01-01T10:05:00Z");
        let b = review_comment(2, Some(1), None, None, None, None, "bob", "2024-01-01T10:05:00Z");

        // Feed in a shuffled order — the output order must not depend on input order.
        let threads = assemble_inline_threads(vec![c.clone(), a.clone(), b.clone()]);
        assert_eq!(threads.len(), 1);
        let ids: Vec<&str> = threads[0].comments.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(
            ids,
            vec!["1", "2", "3"],
            "identical timestamps must be tie-broken by id, deterministically"
        );

        // Re-run with a different input order — same input set, must produce
        // byte-identical thread contents (assembly is a pure function of the
        // input, refetching unchanged data must not reorder anything).
        let threads2 = assemble_inline_threads(vec![b, c, a]);
        assert_eq!(
            serde_json::to_string(&threads).unwrap(),
            serde_json::to_string(&threads2).unwrap(),
            "refetching the same input twice must produce byte-identical thread contents"
        );
    }

    // ── fetch_conversation (W3 — curated-agent-views) ────────────────────────

    /// Build a `GithubClient` from a temp hosts.yml so tests don't require a
    /// real `GITHUB_TOKEN` (mirrors `tests/etag_caching.rs`'s `make_client`).
    fn make_test_client() -> GithubClient {
        let dir = tempfile::tempdir().unwrap();
        let hosts_path = dir.path().join("hosts.yml");
        std::fs::write(
            &hosts_path,
            "github.com:\n  oauth_token: test-token\n  user: tester\n  git_protocol: https\n",
        )
        .unwrap();
        std::env::remove_var("GITHUB_TOKEN");
        let client = GithubClient::new(Some(&hosts_path)).expect("client should build from hosts.yml fixture");
        // Keep the tempdir alive for the client's lifetime (it only reads the
        // file once at construction, so leaking is fine for a short-lived test).
        std::mem::forget(dir);
        client
    }

    fn test_source() -> PerriPrNativeSource {
        PerriPrNativeSource::new(Config::default())
    }

    async fn mount_conversation_mocks(
        server: &wiremock::MockServer,
        owner: &str,
        repo: &str,
        number: u64,
    ) {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, ResponseTemplate};

        Mock::given(method("GET"))
            .and(path(format!("/repos/{owner}/{repo}/issues/{number}/comments")))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {
                    "id": 1,
                    "user": { "login": "alice" },
                    "created_at": "2024-01-01T10:00:00Z",
                    "body": "an issue comment"
                }
            ])))
            .up_to_n_times(1)
            .mount(server)
            .await;

        Mock::given(method("GET"))
            .and(path(format!("/repos/{owner}/{repo}/pulls/{number}/comments")))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {
                    "id": 2,
                    "in_reply_to_id": null,
                    "path": "src/main.rs",
                    "line": 10,
                    "original_line": 10,
                    "diff_hunk": "@@ -1,3 +1,3 @@",
                    "user": { "login": "bob" },
                    "created_at": "2024-01-01T11:00:00Z",
                    "body": "an inline comment"
                }
            ])))
            .up_to_n_times(1)
            .mount(server)
            .await;

        Mock::given(method("GET"))
            .and(path(format!("/repos/{owner}/{repo}/pulls/{number}/reviews")))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {
                    "id": 3,
                    "user": { "login": "carol" },
                    "submitted_at": "2024-01-01T12:00:00Z",
                    "body": "a review body"
                }
            ])))
            .up_to_n_times(1)
            .mount(server)
            .await;
    }

    #[tokio::test]
    async fn fetch_conversation_with_all_three_endpoints_succeeding_produces_no_error_and_the_expected_threads()
    {
        use wiremock::MockServer;

        let server = MockServer::start().await;
        crate::data::perri_queue_native::API_BASE_OVERRIDE
            .with(|c| *c.borrow_mut() = Some(server.uri()));

        mount_conversation_mocks(&server, "acme", "web", 42).await;

        let client = make_test_client();
        let source = test_source();
        let result = source.fetch_conversation(&client, "acme", "web", 42).await;

        assert!(result.error.is_none(), "all three fetches succeeded — error must be None");
        assert_eq!(result.threads.len(), 3, "one issue, one inline, one review thread");
        let kinds: Vec<PrThreadKind> = result.threads.iter().map(|t| t.kind).collect();
        assert!(kinds.contains(&PrThreadKind::Issue));
        assert!(kinds.contains(&PrThreadKind::Inline));
        assert!(kinds.contains(&PrThreadKind::Review));
    }

    #[tokio::test]
    async fn fetch_conversation_with_review_comments_failing_still_returns_the_other_two_threads_and_names_the_failure()
    {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let server = MockServer::start().await;
        crate::data::perri_queue_native::API_BASE_OVERRIDE
            .with(|c| *c.borrow_mut() = Some(server.uri()));

        // Issue comments and reviews succeed...
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/issues/42/comments"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {
                    "id": 1,
                    "user": { "login": "alice" },
                    "created_at": "2024-01-01T10:00:00Z",
                    "body": "an issue comment"
                }
            ])))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/pulls/42/reviews"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {
                    "id": 3,
                    "user": { "login": "carol" },
                    "submitted_at": "2024-01-01T12:00:00Z",
                    "body": "a review body"
                }
            ])))
            .mount(&server)
            .await;
        // ...review comments fails (500).
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/pulls/42/comments"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let client = make_test_client();
        let source = test_source();
        let result = source.fetch_conversation(&client, "acme", "web", 42).await;

        let error = result.error.expect("a partial failure must set an error");
        assert!(
            error.contains("review comments"),
            "the error must name which fetch failed, got: {error}"
        );
        assert_eq!(
            result.threads.len(),
            2,
            "the issue-comment and review threads from the two successful fetches must still be present, \
             not blanked by the review-comments failure, got: {:?}",
            result.threads
        );
        let kinds: Vec<PrThreadKind> = result.threads.iter().map(|t| t.kind).collect();
        assert!(kinds.contains(&PrThreadKind::Issue));
        assert!(kinds.contains(&PrThreadKind::Review));
        assert!(!kinds.contains(&PrThreadKind::Inline));
    }

    #[tokio::test]
    async fn a_second_fetch_conversation_against_unchanged_data_issues_a_conditional_get() {
        use wiremock::matchers::{header, method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let server = MockServer::start().await;
        crate::data::perri_queue_native::API_BASE_OVERRIDE
            .with(|c| *c.borrow_mut() = Some(server.uri()));

        let issue_body = serde_json::json!([
            {
                "id": 1,
                "user": { "login": "alice" },
                "created_at": "2024-01-01T10:00:00Z",
                "body": "an issue comment"
            }
        ]);

        // First call to each endpoint: 200 with an ETag. Expected exactly once.
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/issues/42/comments"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("ETag", "\"issue-etag-1\"")
                    .set_body_json(issue_body.clone()),
            )
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/pulls/42/comments"))
            .respond_with(ResponseTemplate::new(200).insert_header("ETag", "\"rc-etag-1\"").set_body_json(
                serde_json::json!([]),
            ))
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/pulls/42/reviews"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("ETag", "\"review-etag-1\"")
                    .set_body_json(serde_json::json!([])),
            )
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;

        // Second call to each endpoint: matched only when If-None-Match
        // carries the ETag from the first response — proves the conditional
        // GET path actually fired, not just that the value looks the same.
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/issues/42/comments"))
            .and(header("if-none-match", "\"issue-etag-1\""))
            .respond_with(ResponseTemplate::new(304))
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/pulls/42/comments"))
            .and(header("if-none-match", "\"rc-etag-1\""))
            .respond_with(ResponseTemplate::new(304))
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/pulls/42/reviews"))
            .and(header("if-none-match", "\"review-etag-1\""))
            .respond_with(ResponseTemplate::new(304))
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;

        let client = make_test_client();
        // The *same* source instance across both calls — its ETag cache is
        // what makes the second call conditional.
        let source = test_source();

        let first = source.fetch_conversation(&client, "acme", "web", 42).await;
        assert!(first.error.is_none());
        assert_eq!(first.threads.len(), 1);

        let second = source.fetch_conversation(&client, "acme", "web", 42).await;
        assert!(second.error.is_none());
        assert_eq!(
            second.threads.len(),
            1,
            "a 304 must still serve the cached body, not an empty result"
        );

        // `.expect(1)` on each of the six mocks above is checked when the
        // server is torn down — if the conditional GET didn't fire (e.g. a
        // fresh, uncached request went out instead), the "second call" mocks
        // would never have been hit and this would panic on drop.
        server.verify().await;
    }
}
