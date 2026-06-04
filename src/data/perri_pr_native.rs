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

use std::path::{Path, PathBuf};

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
        perri_pr::{CiCheck, PrSnapshot},
        perri_queue::CiState,
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
    let source = PerriPrNativeSource {
        config: config.clone(),
    };
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
}

impl PerriPrNativeSource {
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
            let source = PerriPrNativeSource { config };
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
            ci_checks,
            additions,
            deletions,
            changed_files,
            head_sha,
        })
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
}
