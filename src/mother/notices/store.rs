//! What the notice engine keeps on disk: `~/.nostromo/mother-notices.json`
//! (`0600`, written atomically, a bad file kept as a `.bak` before anything
//! writes over it; see `origin::load_json`).
//!
//! It holds the global switch, each focus's mode, what waits for it (and why),
//! its cap and loop-guard counters, and per job the last state seen, the last
//! state accounted for (told, dropped or not sent) and the notice record the
//! feed shows. Titles and PR URLs of waiting items are in it, as in Mother's
//! own records; nothing here is ever logged.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::batch::Bucket;
use super::limits::Limits;
use super::NoticeView;
use crate::mother::origin::{load_json_checked, write_private, NotifyLevel};

/// The file's name beside the session store.
pub const STORE_FILE: &str = "mother-notices.json";

/// `~/.nostromo/mother-notices.json`'s sibling of `store_path`.
pub fn path_beside(store_path: &Path) -> PathBuf {
    store_path.with_file_name(STORE_FILE)
}

fn on() -> bool {
    true
}

/// The whole file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Store {
    /// The global switch ("Notify sessions").
    #[serde(default = "on")]
    pub enabled: bool,
    #[serde(default)]
    pub focuses: BTreeMap<String, FocusRecord>,
    #[serde(default)]
    pub jobs: BTreeMap<String, JobRecord>,
}

impl Default for Store {
    fn default() -> Self {
        Self {
            enabled: true,
            focuses: BTreeMap::new(),
            jobs: BTreeMap::new(),
        }
    }
}

/// One focus.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct FocusRecord {
    /// The focus's switch; `None` is the default (Wake).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<NotifyLevel>,
    /// When the focus was last in a registry push (or touched by a notice).
    #[serde(default)]
    pub last_seen_ms: i64,
    #[serde(default)]
    pub bucket: Bucket,
    #[serde(default)]
    pub limits: Limits,
}

impl FocusRecord {
    /// Nothing worth keeping beyond its last-seen time.
    pub fn is_trivial(&self) -> bool {
        self.mode.is_none() && self.bucket.is_empty() && self.limits.is_empty()
    }
}

/// What a notice says about a job beyond its state, as last seen.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    #[serde(default)]
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
}

/// One job.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct JobRecord {
    /// Mother's state when last seen.
    pub state: String,
    #[serde(default)]
    pub has_pr: bool,
    #[serde(default)]
    pub last_seen_ms: i64,
    /// When Mother says the job finished (epoch ms); `None` while it runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_ms: Option<i64>,
    /// Mother's state of the job when it was last accounted for: told,
    /// dropped, not sent, or recorded silently (bootstrap, a job nobody is
    /// told about). Kept apart from the notice's event token, which names PR
    /// and retry events that are no Mother state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accounted_state: Option<String>,
    /// Read from a store written before `accounted_state` existed: it held the
    /// last event token, so it says nothing about Mother's state. Never
    /// written; the engine turns it into `accounted_state` on load.
    #[serde(default, skip_serializing)]
    pub last_notified: Option<String>,
    /// The verified focus that queued it, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notify: Option<NotifyLevel>,
    #[serde(default)]
    pub snapshot: Snapshot,
    /// The PR's end, once announced (`true` merged, `false` closed). This is
    /// MF2b's `pr_merged_notified` / `pr_closed_seen`: set when `pr_event` is
    /// accepted, so a relay event, a poll and a restart announce a PR once.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr_final: Option<bool>,
    #[serde(default)]
    pub notice: NoticeView,
}

/// The store at `path` and whether it was loaded. A file that is missing, or
/// present but unreadable or unparseable (kept as a `.bak`), loads nothing: the
/// engine's first look at the feed is then silent, as on a first run.
pub fn load(path: &Path) -> (Store, bool) {
    load_json_checked(path)
}

/// Write `store` to `path`. A failure is logged without content.
pub fn save(path: &Path, store: &Store) {
    if write_private(path, store).is_err() {
        tracing::warn!("mother notice state could not be written");
    }
}
