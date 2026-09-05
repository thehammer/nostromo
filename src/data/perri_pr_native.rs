//! Perri PR-under-review native data source — **multi-tenant** since W7.
//!
//! Reads every focus's pin from `~/.claude/state/perri/current-pr/<tag>.json`
//! (see [`crate::data::perri_current_pr`]), fetches each PR's metadata via
//! `octocrab`, its raw diff, its check-runs and its conversation, and
//! publishes the lot as one [`PrSnapshots`] map keyed by focus tag.
//!
//! ## One task for N focuses
//!
//! There is exactly one of these tasks no matter how many focuses have a PR
//! under review. It fetches sequentially and deduplicates by `(repo, number)`,
//! so two focuses reviewing one PR cost one round trip and share one snapshot.
//! See [`PerriPrNativeSource::spawn`] for why not one task per focus.
//!
//! ## Rate limits
//!
//! Per PR per cycle this makes: one `pulls().get()` (octocrab, uncached), one
//! raw-diff GET, one check-runs GET, and three conversation GETs — all five of
//! the non-octocrab calls conditional (`If-None-Match`). A steady-state cycle
//! against an unchanged PR therefore costs ~1 uncached request rather than the
//! `>=3` it cost before W7, which is what makes running this for N focuses
//! affordable against a shared 5000/hr primary limit.
//!
//! `refresh_tx` carries `Some(tag)` to refetch one focus's pin and `None` for
//! all of them; the `current-pr.dirty` sentinel remains as the "something in
//! the pin directory changed, rescan" fallback.

use std::collections::{HashMap, HashSet};
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
        perri_current_pr,
        perri_pr::{CiCheck, PrComment, PrSnapshot, PrSnapshots, PrThread, PrThreadKind},
        perri_queue::CiState,
        perri_queue_native::{
            api_base, etag_get, etag_get_as, GITHUB_DIFF_ACCEPT, GITHUB_JSON_ACCEPT,
        },
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

/// Ask the PR source to refetch: `Some(tag)` for one focus, `None` for all.
pub type RefreshTx = mpsc::UnboundedSender<Option<String>>;

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
    let source = PerriPrNativeSource::new(config.clone(), None);
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

// ── Source ────────────────────────────────────────────────────────────────────

/// Supplies the set of focus tags that currently exist, or `None` when the
/// daemon does not yet know (no client has pushed a focus registry).
///
/// A closure rather than a handle to the session manager so this module stays
/// free of `ipc` types — and so the "we don't know yet" case has to be spelled
/// out by whoever wires it, rather than being an empty set that silently means
/// "every focus is gone".
pub type LiveFocuses = Arc<dyn Fn() -> Option<HashSet<String>> + Send + Sync>;

pub struct PerriPrNativeSource {
    config: Config,
    /// Backstop for a missed eviction (W7 — D8). Pins are *filtered* here, not
    /// deleted: this runs on every poll, including while a client is
    /// reconnecting and its registry is briefly partial, and a filter that
    /// guesses wrong costs one cycle of a hidden PR while a delete that
    /// guesses wrong is unrecoverable. Genuine deletion happens once, at the
    /// focus-removal hook in `ipc::server`, behind the two-push guard.
    live_focuses: Option<LiveFocuses>,
    /// ETag caches for every conditional GET this source makes: the three
    /// conversation reads (W3 — curated-agent-views) and, since W7, the two
    /// expensive ones — the raw diff and the head SHA's check-runs — so a
    /// refetch against unchanged data costs one 304 instead of a full GitHub
    /// response.
    ///
    /// This is what makes per-focus isolation affordable. Before W7 a poll
    /// cycle cost >=3 *uncached* requests per PR (metadata, the up-to-500 KB
    /// raw diff, check-runs), and there was exactly one PR. Isolation
    /// multiplies that by the number of focuses holding a pin, against a
    /// 5000/hr primary limit the queue source is already spending from. With
    /// these two conditional, a steady-state cycle costs ~0-1 uncached
    /// requests per PR instead.
    ///
    /// Keyed by `(accept, url)` — see [`etag_get_as`] — and pruned each cycle
    /// to the set of URLs the live pins actually need, so a long-lived daemon
    /// working a queue doesn't accumulate every diff it ever fetched.
    ///
    /// `Arc`-shared rather than owned so every construction site (`spawn`,
    /// `prefetch_into_cache`, `fetch_for_cache`) can hand out a cheap clone;
    /// only the long-lived instance `spawn` keeps alive across polling cycles
    /// actually benefits from cache hits, and a fresh one-shot instance simply
    /// starts cold (a full fetch, no correctness issue).
    etags: Arc<Mutex<HashMap<String, String>>>,
    body_cache: Arc<Mutex<HashMap<String, String>>>,
}

impl PerriPrNativeSource {
    /// Build a source instance with fresh, empty conversation caches.
    fn new(config: Config, live_focuses: Option<LiveFocuses>) -> Self {
        PerriPrNativeSource {
            config,
            live_focuses,
            etags: Arc::new(Mutex::new(HashMap::new())),
            body_cache: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Spawn the data source.
    ///
    /// Returns `(snapshots_rx, refresh_tx)`.
    ///
    /// - `snapshots_rx` — watch receiver for the current [`PrSnapshots`]:
    ///   every focus's PR under review, keyed by focus tag.
    /// - `refresh_tx`  — `Some(tag)` triggers an immediate re-fetch of that
    ///   focus's pin, `None` of every pinned focus. `perri.load_pr` sends the
    ///   former; with N focuses pinned, refetching all of them because one
    ///   picked something up would be N-1 wasted GitHub requests.
    ///
    /// **One task, not one per focus** (W7 — D5.2). A task per focus would
    /// mean N `Octocrab`/`reqwest` clients with N connection pools, N ETag
    /// caches that can't share a fetch between two focuses reviewing the same
    /// PR, and N concurrent bursts every poll interval — straight into
    /// GitHub's secondary rate limits. One task fetching sequentially spreads
    /// the same work out, and the accidental serialisation is a feature.
    pub fn spawn(
        config: Config,
        live_focuses: Option<LiveFocuses>,
    ) -> (watch::Receiver<PrSnapshots>, RefreshTx) {
        let (tx, rx) = watch::channel(crate::data::perri_pr::no_prs());
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();
        let (refresh_tx, mut refresh_rx) = mpsc::unbounded_channel::<Option<String>>();

        let state_dir = config.perri_state_dir();
        // One sentinel for the whole pin directory, watched once (D2). The
        // watcher is a 500 ms `exists()` poll; one per focus would be N tasks
        // at 2 Hz for a signal that is always "rescan the directory" anyway.
        dirty_file::spawn_watcher(state_dir.join("current-pr.dirty"), dirty_tx);

        // A pre-W7 global `current-pr.json` is read, logged and deleted here —
        // never adopted. It records what was under review and not who was
        // reviewing it, and guessing an owner is worse than starting empty.
        perri_current_pr::discard_legacy_pointer(&state_dir);

        let interval_secs = config.pr_diff_poll_secs;

        tokio::spawn(async move {
            let source = PerriPrNativeSource::new(config, live_focuses);
            source
                .run(tx, &mut dirty_rx, &mut refresh_rx, interval_secs)
                .await;
        });

        (rx, refresh_tx)
    }

    async fn run(
        &self,
        tx: watch::Sender<PrSnapshots>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
        refresh_rx: &mut mpsc::UnboundedReceiver<Option<String>>,
        interval_secs: u64,
    ) {
        let client = match self.build_client() {
            Ok(c) => c,
            Err(e) => {
                // Terminal, and deliberately still fleet-wide: without a
                // GitHub client no focus can have a PR under review, and
                // turning this into a per-focus failure would mean N copies of
                // one message and a recovery path per tag for a condition that
                // never recovers. The source publishes one error snapshot and
                // stops (unchanged from pre-W7).
                warn!("github client init failed for perri pr: {e:#}");
                let error = Arc::new(PrSnapshot {
                    error: Some(format!("GitHub client init failed: {e:#}")),
                    stale: true,
                    ..Default::default()
                });
                let pins = self.live_pins(&self.config.perri_state_dir());
                let map: HashMap<String, Arc<PrSnapshot>> = pins
                    .into_keys()
                    .map(|tag| (tag, Arc::clone(&error)))
                    .collect();
                let _ = tx.send(Arc::new(map));
                return;
            }
        };

        // Which tags to refetch on this pass. `None` means "all of them" —
        // the timer, the dirty sentinel, and startup.
        let mut only: Option<HashSet<String>> = None;

        loop {
            // Clone the current generation out of the watch borrow *before*
            // awaiting: holding a `watch::Ref` across an await makes the whole
            // future non-`Send` (and would block every reader for the length of
            // a GitHub round trip).
            let previous = tx.borrow().clone();
            let next = self.fetch_all(&client, &previous, only.as_ref()).await;
            let _ = tx.send(next);

            only = None;
            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_secs(interval_secs)) => {}
                // `Some(_) = recv()` disables the branch on a closed channel.
                // The plain `_ =` form matches None and fires every poll once
                // the sender is dropped, producing a hot loop.
                Some(_) = dirty_rx.recv() => {
                    // The sentinel says "the pin directory changed" and not
                    // which file, so this is always a full rescan.
                    debug!("perri diff dirty-file signal");
                }
                Some(tag) = refresh_rx.recv() => {
                    debug!(?tag, "perri diff direct-push refresh signal (MCP)");
                    only = tag.map(|t| HashSet::from([t]));
                }
            }

            // A caller (e.g. `perri.load_pr`) may touch the dirty sentinel
            // *and* send on `refresh_tx` for the same logical change — drain
            // whichever channel(s) didn't win the select above so a single
            // change collapses into exactly one fetch cycle instead of two.
            // Any drained *targeted* refresh widens this pass rather than
            // being dropped: collapsing two focuses' pickups into one fetch of
            // one of them would leave the other stale until the next tick.
            while dirty_rx.try_recv().is_ok() {
                only = None;
            }
            while let Ok(tag) = refresh_rx.try_recv() {
                match (tag, &mut only) {
                    (None, _) => only = None,
                    (Some(_), None) => {}
                    (Some(t), Some(set)) => {
                        set.insert(t);
                    }
                }
            }
        }
    }

    /// Every pin on disk whose focus still exists (W7 — D8).
    ///
    /// With no `live_focuses` provider, or before any client has pushed a
    /// focus registry, every pin is served: "the daemon does not know which
    /// focuses exist" must not read as "no focus exists", which would blank
    /// every focus's PR on a restart before the first push.
    fn live_pins(&self, state_dir: &std::path::Path) -> HashMap<String, perri_current_pr::Pin> {
        let mut pins = perri_current_pr::read_pins(state_dir);
        let Some(live) = self.live_focuses.as_ref().and_then(|f| f()) else {
            return pins;
        };
        pins.retain(|tag, _| {
            let keep = live.contains(tag);
            if !keep {
                debug!(tag = %tag, "ignoring a pin whose focus no longer exists");
            }
            keep
        });
        pins
    }

    /// One polling pass over every focus's pin.
    ///
    /// `previous` is the last published generation; `only` restricts the
    /// *fetching* to those tags (everything else is carried over unchanged).
    /// Tags whose pin has disappeared are dropped from the result regardless
    /// of `only` — that is how a cleared or evicted pin stops being published.
    ///
    /// Fetches are deduplicated by `(repo, number)`: two focuses reviewing the
    /// same PR cost one round trip, not two, and share one snapshot `Arc`.
    async fn fetch_all(
        &self,
        client: &GithubClient,
        previous: &PrSnapshots,
        only: Option<&HashSet<String>>,
    ) -> PrSnapshots {
        let state_dir = self.config.perri_state_dir();
        let pins = self.live_pins(&state_dir);

        // Keep the ETag/body caches to what the live pins can actually ask
        // for. Without this a daemon working a queue accumulates every diff
        // body it has ever fetched, at up to 500 KB each.
        let live_prefixes: Vec<String> = pins
            .values()
            .flat_map(|pin| live_url_prefixes(&pin.repo, pin.number, previous))
            .collect();
        crate::data::perri_queue_native::prune_etag_caches(
            &self.etags,
            &self.body_cache,
            &live_prefixes,
        );

        let mut next: HashMap<String, Arc<PrSnapshot>> = HashMap::new();
        // `(repo, number)` already fetched on this pass — the dedupe (D5).
        let mut fetched: HashMap<(String, u64), Arc<PrSnapshot>> = HashMap::new();

        for (tag, pin) in pins {
            let key = (pin.repo.clone(), pin.number);

            if let Some(shared) = fetched.get(&key) {
                next.insert(tag, Arc::clone(shared));
                continue;
            }

            let carry_over = only.is_some_and(|set| !set.contains(&tag));
            if carry_over {
                if let Some(prev) = previous.get(&tag) {
                    // Only carry over a snapshot that is actually *this* pin's
                    // — a stale snapshot of the focus's previous PR is a wrong
                    // answer, not an old one.
                    if prev.repo == pin.repo && prev.pr_number == Some(pin.number) {
                        fetched.insert(key, Arc::clone(prev));
                        next.insert(tag, Arc::clone(prev));
                        continue;
                    }
                }
            }

            let snap = match self.fetch_pr(client, &pin.repo, pin.number).await {
                Ok(snap) => {
                    debug!(%tag, repo = %pin.repo, pr = pin.number, "perri diff refreshed");
                    self.persist(&state_dir, &pin.repo, pin.number, &snap);
                    Arc::new(snap)
                }
                Err(e) => {
                    // One focus's PR failing must not disturb any other's —
                    // degrade *this* tag to a stale snapshot and keep going.
                    warn!(%tag, repo = %pin.repo, pr = pin.number, "perri diff fetch failed: {e:#}");
                    let mut snap = previous
                        .get(&tag)
                        .filter(|prev| prev.repo == pin.repo && prev.pr_number == Some(pin.number))
                        .map(|prev| (**prev).clone())
                        .unwrap_or_else(|| PrSnapshot {
                            pr_number: Some(pin.number),
                            repo: pin.repo.clone(),
                            ..Default::default()
                        });
                    snap.stale = true;
                    snap.error = Some(e.to_string());
                    Arc::new(snap)
                }
            };

            fetched.insert(key, Arc::clone(&snap));
            next.insert(tag, snap);
        }

        Arc::new(next)
    }

    /// Write the fetched snapshot to the per-PR cache file.
    ///
    /// The pre-W7 single-slot `current-pr-detail.json` is written too, but
    /// only for the *first* pin of a pass and purely as a compatibility
    /// courtesy: a single file cannot describe N focuses, and nothing in this
    /// repo reads it. The per-PR cache (`pr-cache/<repo>-<n>.json`), which
    /// `perri_queue_native`'s prefetch shares, was already per-PR and needs no
    /// change.
    fn persist(&self, state_dir: &Path, repo: &str, number: u64, snap: &PrSnapshot) {
        let json = match serde_json::to_string(snap) {
            Ok(json) => json,
            Err(e) => {
                warn!("perri detail serialize failed: {e:#}");
                return;
            }
        };
        let cache = pr_cache_path(state_dir, repo, number);
        if let Err(e) = write_json_atomic(&cache, &json) {
            warn!("perri detail write (pr-cache) failed: {e:#}");
        }
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
        let raw_diff = fetch_diff(
            client,
            &owner,
            &repo_name,
            number,
            &self.etags,
            &self.body_cache,
        )
        .await?;

        // Apply large-diff threshold: blank the diff and set the flag.
        let (diff, diff_too_large) = if diff_is_too_large(&raw_diff, changed_files) {
            (String::new(), true)
        } else {
            (raw_diff, false)
        };

        // D2/D3: fetch check-runs for the PR head SHA and build CiCheck list.
        let ci_checks = fetch_ci_checks(
            client,
            &owner,
            &repo_name,
            &head_sha,
            &self.etags,
            &self.body_cache,
        )
        .await;

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
        let issue_comments =
            fetch_issue_comments(client, owner, repo, number, &self.etags, &self.body_cache).await;
        let review_comments =
            fetch_review_comments(client, owner, repo, number, &self.etags, &self.body_cache).await;
        let reviews =
            fetch_reviews(client, owner, repo, number, &self.etags, &self.body_cache).await;

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

    fn build_client(&self) -> Result<GithubClient> {
        GithubClient::new(self.config.github_token_path.as_deref())
    }
}

// ── Raw diff fetch ────────────────────────────────────────────────────────────

/// Fetch the PR's raw unified diff — conditionally (W7/D5.1).
///
/// This is the single most expensive request in a poll cycle: an uncached
/// response is the whole diff body, up to [`MAX_DIFF_BYTES`]. Sending
/// `If-None-Match` turns the steady state (a PR nobody has pushed to since the
/// last poll) into a 304 with no body at all, which is what makes running one
/// of these per focus affordable rather than reckless.
async fn fetch_diff(
    client: &GithubClient,
    owner: &str,
    repo: &str,
    number: u64,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Result<String> {
    let url = diff_url(owner, repo, number);
    etag_get_as(client, &url, GITHUB_DIFF_ACCEPT, etags, body_cache)
        .await
        .map_err(|e| anyhow::anyhow!("diff fetch {e}"))
}

/// The URL a PR's raw diff is read from. Shared with [`live_urls_for`] so the
/// cache-pruning set can't drift from what the fetch actually keys on.
fn diff_url(owner: &str, repo: &str, number: u64) -> String {
    format!("{}/repos/{owner}/{repo}/pulls/{number}", api_base())
}

/// The URL a head SHA's check-runs are read from.
fn check_runs_url(owner: &str, repo: &str, head_sha: &str) -> String {
    format!(
        "{}/repos/{owner}/{repo}/commits/{head_sha}/check-runs?per_page=100",
        api_base()
    )
}

/// The URL prefixes a live pin's conditional GETs fall under, for
/// [`crate::data::perri_queue_native::prune_etag_caches`].
///
/// Prefixes, not exact URLs: `/pulls/{n}` covers the raw diff, the review
/// comments and the reviews; `/issues/{n}/` covers the issue comments. A
/// future endpoint added under either is cached correctly without this
/// function being touched.
///
/// The check-runs prefix needs the head SHA, which only a fetched snapshot
/// knows — so it comes from `previous`. A pin whose PR has never been fetched
/// simply contributes no check-runs prefix, which prunes nothing that exists.
fn live_url_prefixes(repo: &str, number: u64, previous: &PrSnapshots) -> Vec<String> {
    let Ok((owner, name)) = split_repo(repo) else {
        return Vec::new();
    };
    let base = api_base();
    let mut prefixes = vec![
        format!("{base}/repos/{owner}/{name}/pulls/{number}"),
        format!("{base}/repos/{owner}/{name}/issues/{number}/"),
    ];
    for snap in previous.values() {
        if snap.repo == repo && snap.pr_number == Some(number) && !snap.head_sha.is_empty() {
            prefixes.push(format!(
                "{base}/repos/{owner}/{name}/commits/{}/",
                snap.head_sha
            ));
        }
    }
    prefixes
}

// ── CI check-runs fetch ───────────────────────────────────────────────────────

/// Fetch check-runs for the PR head SHA and build the `CiCheck` list.
/// On any error, logs a warning and returns an empty vec (diff is primary).
async fn fetch_ci_checks(
    client: &GithubClient,
    owner: &str,
    repo: &str,
    head_sha: &str,
    etags: &Arc<Mutex<HashMap<String, String>>>,
    body_cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Vec<CiCheck> {
    let url = check_runs_url(owner, repo, head_sha);

    // Conditional (W7/D5.1): `?per_page=100` of check-runs is the second
    // biggest response in the cycle and it is unchanged on most polls — a
    // finished CI run's check-runs list never changes again.
    let raw = match etag_get_as(client, &url, GITHUB_JSON_ACCEPT, etags, body_cache).await {
        Ok(body) => body,
        Err(e) => {
            warn!("check-runs fetch failed: {e}");
            return vec![];
        }
    };

    let body: CheckRunsResponse = match serde_json::from_str(&raw) {
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
            .map(|c| {
                (
                    c.path.clone(),
                    c.line.or(c.original_line),
                    c.diff_hunk.clone(),
                )
            })
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
            user: Some(RawGhUser {
                login: author.to_string(),
            }),
            created_at: created_at.parse().unwrap(),
            body: Some(body.to_string()),
        }
    }

    fn review(id: u64, author: &str, submitted_at: Option<&str>, body: Option<&str>) -> RawReview {
        RawReview {
            id,
            user: Some(RawGhUser {
                login: author.to_string(),
            }),
            submitted_at: submitted_at.map(|s| s.parse().unwrap()),
            body: body.map(str::to_string),
            state: "APPROVED".to_string(),
        }
    }

    /// A PENDING (unsubmitted draft) review — no submitted_at, by construction.
    fn pending_review(id: u64, author: &str, body: Option<&str>) -> RawReview {
        RawReview {
            id,
            user: Some(RawGhUser {
                login: author.to_string(),
            }),
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
            user: Some(RawGhUser {
                login: author.to_string(),
            }),
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
            vec![review(
                1,
                "bob",
                Some("2024-01-01T00:00:00Z"),
                Some("looks good"),
            )],
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
        let a = review_comment(
            1,
            None,
            Some("src/main.rs"),
            Some(10),
            None,
            Some("@@ hunk @@"),
            "alice",
            "2024-01-01T10:00:00Z",
        );
        let b = review_comment(
            2,
            Some(1),
            None,
            None,
            None,
            None,
            "bob",
            "2024-01-01T10:05:00Z",
        );
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
    fn a_reply_whose_in_reply_to_id_is_not_present_in_the_payload_becomes_its_own_thread_never_dropped(
    ) {
        // The highest-risk case per the plan: comment 99 replies to comment 1,
        // but comment 1 was never fetched (predates this page, or was
        // filtered out upstream). Comment 99 must become its own thread's
        // root — not be silently dropped.
        let orphan = review_comment(
            99,
            Some(1),
            Some("src/main.rs"),
            Some(20),
            None,
            Some("@@ hunk @@"),
            "carol",
            "2024-01-01T11:00:00Z",
        );
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
        let orphan_a = review_comment(
            101,
            Some(5),
            Some("src/a.rs"),
            Some(1),
            None,
            None,
            "alice",
            "2024-01-01T10:00:00Z",
        );
        let orphan_b = review_comment(
            102,
            Some(5),
            Some("src/b.rs"),
            Some(2),
            None,
            None,
            "bob",
            "2024-01-01T10:01:00Z",
        );
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
            assert_eq!(
                t.comments.len(),
                1,
                "each orphan's thread carries only itself"
            );
        }
    }

    #[test]
    fn a_threads_path_line_and_diff_hunk_come_from_the_root_comment() {
        let root = review_comment(
            1,
            None,
            Some("src/main.rs"),
            Some(10),
            None,
            Some("@@ -1,3 +1,3 @@"),
            "alice",
            "2024-01-01T10:00:00Z",
        );
        let reply = review_comment(
            2,
            Some(1),
            None,
            None,
            None,
            None,
            "bob",
            "2024-01-01T10:05:00Z",
        );
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
        let root = review_comment(
            1,
            None,
            Some("src/main.rs"),
            None,
            Some(7),
            Some("@@ hunk @@"),
            "alice",
            "2024-01-01T10:00:00Z",
        );
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
        let a = review_comment(
            1,
            None,
            Some("f.rs"),
            Some(1),
            None,
            None,
            "alice",
            "2024-01-01T10:00:00Z",
        );
        let c = review_comment(
            3,
            Some(1),
            None,
            None,
            None,
            None,
            "carol",
            "2024-01-01T10:05:00Z",
        );
        let b = review_comment(
            2,
            Some(1),
            None,
            None,
            None,
            None,
            "bob",
            "2024-01-01T10:05:00Z",
        );

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
        let client = GithubClient::new(Some(&hosts_path))
            .expect("client should build from hosts.yml fixture");
        // Keep the tempdir alive for the client's lifetime (it only reads the
        // file once at construction, so leaking is fine for a short-lived test).
        std::mem::forget(dir);
        client
    }

    fn test_source() -> PerriPrNativeSource {
        PerriPrNativeSource::new(Config::default(), None)
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
            .and(path(format!(
                "/repos/{owner}/{repo}/issues/{number}/comments"
            )))
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
            .and(path(format!(
                "/repos/{owner}/{repo}/pulls/{number}/comments"
            )))
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
            .and(path(format!(
                "/repos/{owner}/{repo}/pulls/{number}/reviews"
            )))
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
    async fn fetch_conversation_with_all_three_endpoints_succeeding_produces_no_error_and_the_expected_threads(
    ) {
        use wiremock::MockServer;

        let server = MockServer::start().await;
        crate::data::perri_queue_native::API_BASE_OVERRIDE
            .with(|c| *c.borrow_mut() = Some(server.uri()));

        mount_conversation_mocks(&server, "acme", "web", 42).await;

        let client = make_test_client();
        let source = test_source();
        let result = source.fetch_conversation(&client, "acme", "web", 42).await;

        assert!(
            result.error.is_none(),
            "all three fetches succeeded — error must be None"
        );
        assert_eq!(
            result.threads.len(),
            3,
            "one issue, one inline, one review thread"
        );
        let kinds: Vec<PrThreadKind> = result.threads.iter().map(|t| t.kind).collect();
        assert!(kinds.contains(&PrThreadKind::Issue));
        assert!(kinds.contains(&PrThreadKind::Inline));
        assert!(kinds.contains(&PrThreadKind::Review));
    }

    #[tokio::test]
    async fn fetch_conversation_with_review_comments_failing_still_returns_the_other_two_threads_and_names_the_failure(
    ) {
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
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("ETag", "\"rc-etag-1\"")
                    .set_body_json(serde_json::json!([])),
            )
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

    // ── the two expensive calls are conditional (W7 — D5.1) ─────────────────
    //
    // The rate-limit regression guard. Before W7 the raw diff (up to
    // MAX_DIFF_BYTES) and check-runs went out uncached on every poll, so a
    // cycle cost >=3 uncached requests per PR and there was exactly one PR.
    // Per-focus isolation multiplies that by the number of focuses holding a
    // pin, against a 5000/hr limit the queue source is already spending from —
    // this repo has three separate documented fixes for that exact failure
    // (docs/perri-rl-fix-1.md, -2.md, -3.md).
    //
    // A refactor that drops either `etag_get_as` call is silent: everything
    // still works, and the only symptom is rate-limit exhaustion in
    // production. Hence a test that asserts on what actually goes out on the
    // wire.

    /// The diff and check-runs requests of a second poll against unchanged
    /// data must carry `If-None-Match`, and the 304 must still yield the
    /// cached content rather than a blanked snapshot.
    #[tokio::test]
    async fn a_second_poll_sends_conditional_gets_for_the_diff_and_the_check_runs() {
        use wiremock::matchers::{header, method, path, query_param};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let server = MockServer::start().await;
        crate::data::perri_queue_native::API_BASE_OVERRIDE
            .with(|c| *c.borrow_mut() = Some(server.uri()));

        const HEAD: &str = "abc123";
        const DIFF: &str = "diff --git a/src/main.rs b/src/main.rs\n+hello\n";

        // The raw diff — same path as the metadata call, distinguished by its
        // Accept header, which is also what keys the ETag cache.
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/pulls/42"))
            .and(header("accept", GITHUB_DIFF_ACCEPT))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("ETag", "\"diff-etag-1\"")
                    .set_body_string(DIFF),
            )
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/pulls/42"))
            .and(header("accept", GITHUB_DIFF_ACCEPT))
            .and(header("if-none-match", "\"diff-etag-1\""))
            .respond_with(ResponseTemplate::new(304))
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;

        // check-runs for the head SHA.
        let checks = serde_json::json!({
            "total_count": 1,
            "check_runs": [
                { "id": 7, "name": "build", "status": "completed",
                  "conclusion": "success",
                  "app": { "slug": "circleci" } }
            ]
        });
        Mock::given(method("GET"))
            .and(path(format!("/repos/acme/web/commits/{HEAD}/check-runs")))
            .and(query_param("per_page", "100"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("ETag", "\"checks-etag-1\"")
                    .set_body_json(checks),
            )
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path(format!("/repos/acme/web/commits/{HEAD}/check-runs")))
            .and(query_param("per_page", "100"))
            .and(header("if-none-match", "\"checks-etag-1\""))
            .respond_with(ResponseTemplate::new(304))
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;

        mount_conversation_mocks(&server, "acme", "web", 42).await;

        // PR metadata — octocrab, unconditional by design, and mounted *last*
        // so it acts as the fallback for `/pulls/42`. The diff shares that
        // path and is distinguished only by its `Accept` header (which is
        // also what keys its ETag cache), so the specific diff mocks above
        // must be offered the request first.
        Mock::given(method("GET"))
            .and(path("/repos/acme/web/pulls/42"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "url": "https://api.github.com/repos/acme/web/pulls/42",
                "id": 1001, "node_id": "PR_1001",
                "number": 42, "title": "Add widget", "state": "open",
                "user": {
                    "login": "alice", "id": 1, "node_id": "U_1",
                    "avatar_url": "https://example.com/a.png",
                    "gravatar_id": "", "url": "https://api.github.com/users/alice",
                    "html_url": "https://github.com/alice",
                    "followers_url": "https://api.github.com/users/alice/followers",
                    "following_url": "https://api.github.com/users/alice/following{/other_user}",
                    "gists_url": "https://api.github.com/users/alice/gists{/gist_id}",
                    "starred_url": "https://api.github.com/users/alice/starred{/owner}{/repo}",
                    "subscriptions_url": "https://api.github.com/users/alice/subscriptions",
                    "organizations_url": "https://api.github.com/users/alice/orgs",
                    "repos_url": "https://api.github.com/users/alice/repos",
                    "events_url": "https://api.github.com/users/alice/events{/privacy}",
                    "received_events_url": "https://api.github.com/users/alice/received_events",
                    "type": "User", "site_admin": false
                },
                "html_url": "https://github.com/acme/web/pull/42",
                "additions": 10, "deletions": 2, "changed_files": 3,
                "head": { "sha": HEAD, "label": "acme:feature", "ref": "feature" },
                "base": { "sha": "def456", "label": "acme:main", "ref": "main" },
            })))
            .mount(&server)
            .await;

        let client = client_pointed_at(&server.uri());
        // The *same* source across both passes — its ETag cache is what makes
        // the second pass conditional.
        let source = test_source();

        let first = source.fetch_pr(&client, "acme/web", 42).await.unwrap();
        assert_eq!(first.diff, DIFF);
        assert_eq!(
            first.ci_checks.len(),
            1,
            "the first pass must see the check"
        );

        let second = source.fetch_pr(&client, "acme/web", 42).await.unwrap();
        assert_eq!(
            second.diff, DIFF,
            "a 304 must serve the cached diff body, not blank it — a pane \
             rendering an empty diff because nothing changed is the failure \
             this whole path exists to avoid"
        );
        assert_eq!(
            second.ci_checks.len(),
            1,
            "a 304 must serve the cached check-runs, not drop them"
        );

        // Each `.expect(1)` is verified on teardown: if either conditional GET
        // had not fired — an uncached request going out instead — its mock
        // would be unmatched and the unconditional mock would have been hit
        // twice, failing both counts.
        server.verify().await;
    }

    // ── the poll dedupes by (repo, number), not by focus (W7 — D5) ───────────
    //
    // Two focuses reviewing the same PR is an ordinary state after W7 (the
    // pickup is never gated), and the PRD's queue/traffic story only holds if
    // N focuses on one PR cost the fetch of one. These tests drive the real
    // `fetch_all` against a `wiremock` GitHub and count what actually went out
    // on the wire — never a wall-clock or a timing window.

    /// A `GithubClient` whose *every* path — octocrab's typed calls and the
    /// raw ETag'd ones — lands on `base`. `API_BASE_OVERRIDE` only redirects
    /// the latter, so a client built the production way would still send the
    /// PR-metadata call to api.github.com.
    fn client_pointed_at(base: &str) -> GithubClient {
        let octocrab = octocrab::Octocrab::builder()
            .base_uri(base)
            .expect("wiremock's uri is a valid base uri")
            .personal_token("test-token".to_string())
            .build()
            .expect("octocrab client should build");
        GithubClient {
            octocrab,
            http: reqwest::Client::new(),
            token: "test-token".to_string(),
        }
    }

    /// A source whose pins live in `dir`, with fresh (empty) ETag/body caches
    /// so every scenario below starts from the same cold state and their
    /// request counts are comparable.
    fn source_pinned_at(dir: &Path) -> PerriPrNativeSource {
        PerriPrNativeSource::new(
            Config {
                perri_state: Some(dir.to_path_buf()),
                ..Config::default()
            },
            None,
        )
    }

    /// Run one polling pass over `pins` (`(tag, repo, number)`) against a
    /// throwaway mock GitHub, returning the published snapshots and how many
    /// requests reached the server.
    ///
    /// Nothing is mounted: every call 404s, so `fetch_pr` fails and each pin
    /// degrades to a stale snapshot. That is deliberate — the dedupe happens
    /// *before* the fetch, so a failing fetch exercises exactly the same
    /// keying while keeping the test hermetic, and the request count stays a
    /// faithful measure of how many round trips a pass costs.
    async fn poll_once(pins: &[(&str, &str, u64)]) -> (PrSnapshots, usize) {
        let server = wiremock::MockServer::start().await;
        crate::data::perri_queue_native::API_BASE_OVERRIDE
            .with(|c| *c.borrow_mut() = Some(server.uri()));

        let dir = tempfile::TempDir::new().unwrap();
        for (tag, repo, number) in pins {
            perri_current_pr::write_pointer(dir.path(), tag, *number, repo, None).unwrap();
        }

        let source = source_pinned_at(dir.path());
        let client = client_pointed_at(&server.uri());
        let snaps = source
            .fetch_all(&client, &crate::data::perri_pr::no_prs(), None)
            .await;
        let requests = server.received_requests().await.unwrap_or_default().len();
        (snaps, requests)
    }

    #[tokio::test]
    async fn two_focuses_pinned_to_the_same_pr_cost_the_same_github_traffic_as_one() {
        let (_, one_focus) = poll_once(&[("perri", "Carefeed/admin-portal", 4526)]).await;
        assert!(
            one_focus > 0,
            "the baseline pass must actually have hit GitHub, or the comparison below is vacuous"
        );

        let (snaps, two_focuses) = poll_once(&[
            ("perri", "Carefeed/admin-portal", 4526),
            ("operations", "Carefeed/admin-portal", 4526),
        ])
        .await;

        assert_eq!(
            two_focuses, one_focus,
            "a second focus pinned to the same PR must add no GitHub traffic at all"
        );
        assert_eq!(
            snaps.len(),
            2,
            "both focuses must still be published, deduped fetch or not"
        );
        assert!(
            std::sync::Arc::ptr_eq(&snaps["perri"], &snaps["operations"]),
            "the two focuses must share the one fetched snapshot, not two copies of it"
        );
    }

    #[tokio::test]
    async fn the_dedupe_is_keyed_on_repo_and_number_so_two_different_prs_are_two_fetches() {
        let (_, one_focus) = poll_once(&[("perri", "Carefeed/admin-portal", 4526)]).await;

        // Same repo, different number — the case a repo-keyed dedupe would
        // wrongly collapse into one fetch, silently serving focus B focus A's
        // PR. This is the same line the PRD draws against repo-scoping.
        let (same_repo, same_repo_requests) = poll_once(&[
            ("perri", "Carefeed/admin-portal", 4526),
            ("operations", "Carefeed/admin-portal", 4527),
        ])
        .await;
        assert!(
            same_repo_requests > one_focus,
            "two PRs in one repo are two PRs: {same_repo_requests} requests must exceed the \
             {one_focus} a single pin costs"
        );
        assert!(
            !std::sync::Arc::ptr_eq(&same_repo["perri"], &same_repo["operations"]),
            "two different PRs must never share a snapshot, however close their repos"
        );
        assert_eq!(same_repo["perri"].pr_number, Some(4526));
        assert_eq!(same_repo["operations"].pr_number, Some(4527));

        // Different repo, same number — the mirror case, which a
        // number-keyed dedupe would collapse.
        let (different_repo, different_repo_requests) = poll_once(&[
            ("perri", "Carefeed/admin-portal", 42),
            ("operations", "Carefeed/operations", 42),
        ])
        .await;
        assert!(
            different_repo_requests > one_focus,
            "the same number in two repos is two PRs"
        );
        assert_eq!(different_repo["perri"].repo, "Carefeed/admin-portal");
        assert_eq!(different_repo["operations"].repo, "Carefeed/operations");
    }
}
