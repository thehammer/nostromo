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

use std::path::PathBuf;

use anyhow::{Context, Result};
use reqwest::header::{ACCEPT, AUTHORIZATION};
use serde::Deserialize;
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{
    config::Config,
    data::{dirty_file, github_client::GithubClient, perri_pr::PrSnapshot},
};

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

        let (owner, repo_name) = split_repo(&pointer.repo)?;

        // Fetch PR metadata via octocrab for authoritative fields.
        let pr_meta = client
            .octocrab
            .pulls(&owner, &repo_name)
            .get(pointer.number)
            .await
            .with_context(|| format!("fetching PR {}/{} #{}", owner, repo_name, pointer.number))?;

        let title = pr_meta
            .title
            .clone()
            .unwrap_or_else(|| pointer.title.clone().unwrap_or_default());
        let author = pr_meta
            .user
            .as_ref()
            .map(|u| u.login.clone())
            .unwrap_or_else(|| pointer.author.clone().unwrap_or_default());
        let url = pr_meta
            .html_url
            .as_ref()
            .map(|u| u.to_string())
            .unwrap_or_else(|| pointer.url.clone().unwrap_or_default());

        // Fetch the raw diff.
        let diff = fetch_diff(client, &owner, &repo_name, pointer.number).await?;

        Ok(PrSnapshot {
            pr_number: Some(pointer.number),
            repo: pointer.repo.clone(),
            title,
            author,
            url,
            diff,
            stale: false,
            error: None,
        })
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
