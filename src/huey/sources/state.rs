//! Per-source state: what Huey has already seen, so an undated source can be
//! baselined and an item is judged against the window by when it was first
//! seen.
//!
//! One JSON file per source, `<state dir>/sources/<source id>.json`, written
//! atomically (temp file plus rename).

use std::collections::{BTreeMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::huey::items::NewsItem;

/// An entry nobody has listed for this long is forgotten.
const FORGET_AFTER_DAYS: i64 = 90;
/// How far back `recent` keeps full items, for answering a 304 or surviving
/// a failed fetch.
///
/// Longer than the longest plausible report window (the 7-day first-run
/// window plus a margin), so a 304 or a failed fetch after weeks without a
/// report does not lose items.
pub const RECENT_DAYS: i64 = 21;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ItemState {
    pub first_seen_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub published_at: Option<DateTime<Utc>>,
    /// Set on the very first successful fetch of an undated item. Such an
    /// item is never eligible: it was already there when Huey started.
    #[serde(default)]
    pub baseline: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SourceState {
    pub last_attempt_at: Option<DateTime<Utc>>,
    pub last_ok_at: Option<DateTime<Utc>>,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub baseline_done: bool,
    pub items: BTreeMap<String, ItemState>,
    /// Full copies of the non-baseline items seen in the last
    /// [`RECENT_DAYS`] days by a successful fetch. A 304 carries no body and
    /// a failed fetch carries nothing, yet items first seen earlier and not
    /// yet reported must still reach the next report.
    pub recent: Vec<NewsItem>,
}

/// Whether an item belongs in this report's window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Eligibility {
    Eligible,
    /// Undated, and already there when Huey first read the source.
    Baseline,
    BeforeWindow,
}

pub fn state_file(state_dir: &Path, source_id: &str) -> PathBuf {
    state_dir.join("sources").join(format!("{source_id}.json"))
}

/// A missing file is a source never read. A damaged one is the same, with a
/// warning: re-baselining loses nothing a reader could have seen twice.
pub fn load(state_dir: &Path, source_id: &str) -> SourceState {
    let path = state_file(state_dir, source_id);
    match std::fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|_| {
            warn!(
                source = source_id,
                "huey: source state unreadable; starting over"
            );
            SourceState::default()
        }),
        Err(e) if e.kind() == io::ErrorKind::NotFound => SourceState::default(),
        Err(_) => {
            warn!(source = source_id, "huey: source state could not be read");
            SourceState::default()
        }
    }
}

/// Save a source's state. Nothing is created unless the Huey root (the
/// parent of `state_dir`) already exists: a Huey that was never set up leaves
/// no trace.
pub fn save(state_dir: &Path, source_id: &str, state: &SourceState) -> io::Result<()> {
    write_json_private(state_dir.parent(), &state_file(state_dir, source_id), state)
}

/// Serialize `value` to `path` with setup's owner-only writer (0700
/// directories, 0600 file, fsync before the rename), but only when `root`
/// exists. A missing root is "not set up": `NotFound`, nothing created.
pub(crate) fn write_json_private<T: Serialize>(
    root: Option<&Path>,
    path: &Path,
    value: &T,
) -> io::Result<()> {
    if !root.is_some_and(Path::is_dir) {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "huey is not set up: no state root",
        ));
    }
    let bytes = serde_json::to_vec(value).map_err(io::Error::other)?;
    crate::huey::setup::write_atomic(path, &bytes)
}

/// The one place the window and the baseline are decided.
///
/// A dated item is in the window when it was published at or after
/// `window_start`. An undated item is in the window when Huey first saw it at
/// or after `window_start`, unless it is baseline. `item.first_seen_at` must
/// already come from [`record`].
pub fn eligible(item: &NewsItem, state: &SourceState, window_start: DateTime<Utc>) -> Eligibility {
    match item.published_at {
        Some(published) if published >= window_start => Eligibility::Eligible,
        Some(_) => Eligibility::BeforeWindow,
        None if is_baseline(item, state) => Eligibility::Baseline,
        None if item.first_seen_at >= window_start => Eligibility::Eligible,
        None => Eligibility::BeforeWindow,
    }
}

/// Undated and already there when Huey first read its source.
pub fn is_baseline(item: &NewsItem, state: &SourceState) -> bool {
    item.published_at.is_none() && state.items.get(&item.id).is_some_and(|s| s.baseline)
}

/// Note the items a successful fetch returned: stamp each with when it was
/// first seen, and on the source's first successful fetch mark every undated
/// item as baseline.
pub fn record(state: &mut SourceState, items: &mut [NewsItem], now: DateTime<Utc>) {
    let first_fetch = !state.baseline_done;
    for item in items.iter_mut() {
        match state.items.get_mut(&item.id) {
            Some(known) => {
                item.first_seen_at = known.first_seen_at;
                // A date once learned sticks: a source that stops giving it
                // (npm down for a day) must not turn an old item into a new one.
                match item.published_at {
                    Some(_) if known.published_at.is_none() => {
                        known.published_at = item.published_at
                    }
                    None => item.published_at = known.published_at,
                    Some(_) => {}
                }
            }
            None => {
                item.first_seen_at = now;
                state.items.insert(
                    item.id.clone(),
                    ItemState {
                        first_seen_at: now,
                        published_at: item.published_at,
                        baseline: first_fetch && item.published_at.is_none(),
                    },
                );
            }
        }
    }
    state.baseline_done = true;
}

/// Forget entries the source no longer lists and nobody has seen for
/// [`FORGET_AFTER_DAYS`]. An entry still listed is kept however old: dropping
/// it would make an undated item look new again.
pub fn prune(state: &mut SourceState, listed: &HashSet<&str>, now: DateTime<Utc>) {
    let cutoff = now - Duration::days(FORGET_AFTER_DAYS);
    state
        .items
        .retain(|id, s| listed.contains(id.as_str()) || s.first_seen_at >= cutoff);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::huey::items::SourceClass;
    use chrono::TimeZone;

    fn at(day: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, day, 12, 0, 0).unwrap()
    }

    fn item(id: &str, published: Option<DateTime<Utc>>) -> NewsItem {
        NewsItem {
            id: id.to_string(),
            source_id: "s".to_string(),
            class: SourceClass::FirstParty,
            title: id.to_string(),
            url: format!("https://x.test/{id}"),
            canonical_url: format!("https://x.test/{id}"),
            published_at: published,
            first_seen_at: at(1),
            text: String::new(),
            outbound_links: vec![],
        }
    }

    #[test]
    fn the_first_fetch_baselines_undated_items_only() {
        let mut state = SourceState::default();
        let mut items = vec![item("a", None), item("b", Some(at(20)))];
        record(&mut state, &mut items, at(21));
        assert!(state.baseline_done);
        assert_eq!(eligible(&items[0], &state, at(14)), Eligibility::Baseline);
        assert_eq!(eligible(&items[1], &state, at(14)), Eligibility::Eligible);
    }

    #[test]
    fn a_later_new_undated_item_is_eligible_and_keeps_its_first_seen_time() {
        let mut state = SourceState::default();
        record(&mut state, &mut [item("a", None)], at(21));
        let mut items = vec![item("a", None), item("n", None)];
        record(&mut state, &mut items, at(23));
        assert_eq!(eligible(&items[0], &state, at(22)), Eligibility::Baseline);
        assert_eq!(eligible(&items[1], &state, at(22)), Eligibility::Eligible);
        // Seen again later: still first seen at 23, so still in a window from 22.
        let mut again = vec![item("n", None)];
        record(&mut state, &mut again, at(25));
        assert_eq!(again[0].first_seen_at, at(23));
        assert_eq!(eligible(&again[0], &state, at(22)), Eligibility::Eligible);
        assert_eq!(
            eligible(&again[0], &state, at(24)),
            Eligibility::BeforeWindow
        );
    }

    #[test]
    fn a_dated_item_is_judged_by_its_date_not_when_it_was_seen() {
        let state = SourceState::default();
        let mut old = item("o", Some(at(10)));
        old.first_seen_at = at(24);
        assert_eq!(eligible(&old, &state, at(20)), Eligibility::BeforeWindow);
        assert_eq!(eligible(&old, &state, at(10)), Eligibility::Eligible);
    }

    #[test]
    fn an_undated_item_that_later_gets_a_date_is_judged_by_it() {
        let mut state = SourceState::default();
        record(&mut state, &mut [item("a", None)], at(21));
        let dated = item("a", Some(at(24)));
        assert_eq!(eligible(&dated, &state, at(22)), Eligibility::Eligible);
    }

    #[test]
    fn a_date_once_learned_survives_a_fetch_that_lacks_it() {
        let mut state = SourceState::default();
        record(&mut state, &mut [item("a", Some(at(5)))], at(21));
        let mut again = vec![item("a", None)];
        record(&mut state, &mut again, at(22));
        assert_eq!(again[0].published_at, Some(at(5)));
        assert_eq!(
            eligible(&again[0], &state, at(10)),
            Eligibility::BeforeWindow
        );
    }

    #[test]
    fn prune_keeps_listed_entries_however_old() {
        let mut state = SourceState::default();
        record(
            &mut state,
            &mut [item("listed", None), item("gone", None)],
            at(1),
        );
        let later = at(1) + Duration::days(200);
        prune(&mut state, &HashSet::from(["listed"]), later);
        assert!(state.items.contains_key("listed"));
        assert!(!state.items.contains_key("gone"));
    }

    #[test]
    fn save_then_load_round_trips_and_leaves_no_temp_files() {
        let dir = tempfile::tempdir().unwrap();
        let mut state = SourceState::default();
        record(&mut state, &mut [item("a", None)], at(21));
        state.etag = Some("\"e1\"".to_string());
        save(dir.path(), "src", &state).unwrap();
        assert_eq!(load(dir.path(), "src"), state);
        let names: Vec<_> = std::fs::read_dir(dir.path().join("sources"))
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(names, ["src.json"]);
    }

    #[cfg(unix)]
    #[test]
    fn state_directories_are_0700_and_files_0600() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let state_dir = root.path().join("state");
        save(&state_dir, "src", &SourceState::default()).unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&state_dir), 0o700);
        assert_eq!(mode(&state_dir.join("sources")), 0o700);
        assert_eq!(mode(&state_file(&state_dir, "src")), 0o600);
    }

    #[test]
    fn saving_without_a_huey_root_creates_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("huey");
        let err = save(&root.join("state"), "src", &SourceState::default()).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::NotFound);
        assert!(!root.exists());
        assert_eq!(std::fs::read_dir(tmp.path()).unwrap().count(), 0);
    }

    #[test]
    fn a_damaged_file_loads_as_a_fresh_source() {
        let dir = tempfile::tempdir().unwrap();
        let path = state_file(dir.path(), "src");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"{not json").unwrap();
        assert_eq!(load(dir.path(), "src"), SourceState::default());
    }
}
