//! `fetch_all`: read every enabled source at once and say, per source, what
//! came back. Plus the frozen daily pool (`pool/<date>.json`).
//!
//! One source failing never touches another. A source that answered but has
//! nothing in the window is `Quiet`; one that timed out, answered with an
//! error or sent something unparseable is `Failed` with a plain reason.

use std::collections::HashSet;
use std::io;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use tracing::{debug, warn};

use super::config::{SourceConfig, SourcesConfig};
use super::http::{FetchError, HttpClient};
use super::state::{self, Eligibility};
use super::{fetch_source, AdapterCtx};
use crate::huey::items::{NewsItem, SourceClass};

/// Items first seen or published within this many days make up the pool the
/// Also-in-the-news line draws on, whatever the report window is.
pub const RECENT_POOL_DAYS: i64 = 7;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum SourceOutcome {
    /// Read, with `new` items in the window.
    Ok {
        new: usize,
    },
    /// Read, and nothing in the window.
    Quiet,
    Failed {
        reason: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SourceStatus {
    pub id: String,
    pub name: String,
    pub class: SourceClass,
    pub outcome: SourceOutcome,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct FetchOutcome {
    /// Items in the window, newest first.
    pub items: Vec<NewsItem>,
    /// Every non-baseline item first seen or published in the last
    /// [`RECENT_POOL_DAYS`] days, whether or not it is in the window, newest
    /// first. First-party ones are the Also-in-the-news candidates.
    pub recent: Vec<NewsItem>,
    /// One per enabled source, in `sources.toml` order.
    pub statuses: Vec<SourceStatus>,
    /// When this fetch ran: the items run up to here, so the next window
    /// starts after it (a regeneration on the frozen pool keeps it).
    #[serde(default)]
    pub fetched_at: Option<DateTime<Utc>>,
}

struct SourceResult {
    status: SourceStatus,
    items: Vec<NewsItem>,
    recent: Vec<NewsItem>,
}

/// Fetch every enabled source in `cfg`.
///
/// `state_dir` is the Huey `state` directory; per-source state lives in
/// `<state_dir>/sources/<id>.json`. Items are judged against `window_start`
/// (see [`state::eligible`]). An item first seen during a run that later
/// failed stays in the window, because the window is the caller's.
///
/// A source that fails still returns items from its last successful fetch
/// that are in the window, so an item first seen earlier is not lost to a
/// bad day at the source.
pub async fn fetch_all(
    cfg: &SourcesConfig,
    state_dir: &Path,
    window_start: DateTime<Utc>,
    now: DateTime<Utc>,
    http: &HttpClient,
) -> FetchOutcome {
    let results = futures::future::join_all(
        cfg.enabled()
            .map(|src| run_source(src, state_dir, window_start, now, http)),
    )
    .await;
    let mut out = FetchOutcome {
        fetched_at: Some(now),
        ..FetchOutcome::default()
    };
    for r in results {
        out.items.extend(r.items);
        out.recent.extend(r.recent);
        out.statuses.push(r.status);
    }
    newest_first(&mut out.items);
    newest_first(&mut out.recent);
    out
}

async fn run_source(
    src: &SourceConfig,
    state_dir: &Path,
    window_start: DateTime<Utc>,
    now: DateTime<Utc>,
    http: &HttpClient,
) -> SourceResult {
    let mut state = state::load(state_dir, &src.id);
    state.last_attempt_at = Some(now);

    // The whole-fetch limit applies to every source alike, so the tighter of
    // the two bounds one source.
    let limits = http.limits();
    let budget = limits.per_source.min(limits.overall);
    let fetched = {
        let ctx = AdapterCtx {
            http,
            now,
            state: &state,
        };
        match tokio::time::timeout(budget, fetch_source(src, &ctx)).await {
            Ok(result) => result,
            Err(_) => Err(FetchError::Timeout),
        }
    };

    let (failure, candidates) = match fetched {
        Err(e) => (Some(e.to_string()), state.recent.clone()),
        Ok(None) => {
            state.last_ok_at = Some(now);
            (None, state.recent.clone())
        }
        Ok(Some(mut fetch)) => {
            state::record(&mut state, &mut fetch.items, now);
            let listed: HashSet<&str> = fetch.items.iter().map(|i| i.id.as_str()).collect();
            state::prune(&mut state, &listed, now);
            state.etag = fetch.etag;
            state.last_modified = fetch.last_modified;
            state.last_ok_at = Some(now);
            let keep_after = now - Duration::days(state::RECENT_DAYS);
            state.recent = fetch
                .items
                .iter()
                .filter(|i| !state::is_baseline(i, &state) && i.effective_time() >= keep_after)
                .cloned()
                .collect();
            (None, fetch.items)
        }
    };

    let recent_after = now - Duration::days(RECENT_POOL_DAYS);
    let mut items = Vec::new();
    let mut recent = Vec::new();
    for item in candidates {
        let eligibility = state::eligible(&item, &state, window_start);
        if eligibility != Eligibility::Baseline && item.effective_time() >= recent_after {
            recent.push(item.clone());
        }
        if eligibility == Eligibility::Eligible {
            items.push(item);
        }
    }

    let outcome = match failure {
        Some(reason) => SourceOutcome::Failed { reason },
        None if items.is_empty() => SourceOutcome::Quiet,
        None => SourceOutcome::Ok { new: items.len() },
    };
    debug!(
        source = %src.id,
        in_window = items.len(),
        failed = matches!(outcome, SourceOutcome::Failed { .. }),
        "huey: source read"
    );
    if state::save(state_dir, &src.id, &state).is_err() {
        warn!(source = %src.id, "huey: source state could not be saved");
    }
    SourceResult {
        status: SourceStatus {
            id: src.id.clone(),
            name: src.name.clone(),
            class: src.class,
            outcome,
        },
        items,
        recent,
    }
}

fn newest_first(items: &mut [NewsItem]) {
    items.sort_by(|a, b| {
        b.effective_time()
            .cmp(&a.effective_time())
            .then_with(|| a.id.cmp(&b.id))
    });
}

// ── The daily pool ───────────────────────────────────────────────────────────

pub fn pool_file(pool_dir: &Path, date: NaiveDate) -> PathBuf {
    pool_dir.join(format!("{date}.json"))
}

/// Freeze `outcome` as the pool for `date`, replacing an earlier one.
pub fn save_pool(pool_dir: &Path, date: NaiveDate, outcome: &FetchOutcome) -> io::Result<()> {
    state::write_json_private(pool_dir.parent(), &pool_file(pool_dir, date), outcome)
}

/// The frozen pool for `date`, if there is a readable one.
pub fn load_pool(pool_dir: &Path, date: NaiveDate) -> Option<FetchOutcome> {
    let bytes = std::fs::read(pool_file(pool_dir, date)).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Delete pools more than `keep_days` older than `today`. Returns how many
/// went. Files that are not `<date>.json` are left alone.
pub fn prune_pool(pool_dir: &Path, today: NaiveDate, keep_days: i64) -> usize {
    let Ok(entries) = std::fs::read_dir(pool_dir) else {
        return 0;
    };
    let mut removed = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        let date = path
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(|n| n.strip_suffix(".json"))
            .and_then(|n| n.parse::<NaiveDate>().ok());
        if date.is_some_and(|d| (today - d).num_days() > keep_days)
            && std::fs::remove_file(&path).is_ok()
        {
            removed += 1;
        }
    }
    removed
}
