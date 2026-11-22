//! What the user decided about a PR, kept across restarts: which focus it is
//! linked to (a picker choice) and which focus was last told about it.
//!
//! Persisted at `<state_root>/authored-pr-links.json`, mode 0600, keyed by
//! lowercased `owner/name#number`. An entry holds a link `{tag, at}` and a
//! told record `{tag, at, attention_key}` and **nothing else**: no title,
//! branch, check or comment data (SP5). Entries end when the PR is seen merged
//! or closed, or when nothing has touched them for 30 days and the PR is gone;
//! there are at most 500, the oldest dropped first.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::mother::origin::{load_json_checked, write_private};

pub const MAX_ENTRIES: usize = 500;
pub const MAX_AGE_DAYS: i64 = 30;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkRecord {
    pub tag: String,
    pub at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToldRecord {
    pub tag: String,
    pub at: DateTime<Utc>,
    pub attention_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Entry {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<LinkRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub told: Option<ToldRecord>,
}

impl Entry {
    fn newest(&self) -> Option<DateTime<Utc>> {
        self.link
            .as_ref()
            .map(|l| l.at)
            .into_iter()
            .chain(self.told.as_ref().map(|t| t.at))
            .max()
    }
}

/// `owner/name#number`, lowercased.
pub fn key_string(repo: &str, number: u64) -> String {
    format!("{}#{number}", repo.to_ascii_lowercase())
}

/// Links and told records. Cheap to share behind an `Arc`.
pub struct AuthoredPrStore {
    path: Option<PathBuf>,
    entries: Mutex<BTreeMap<String, Entry>>,
}

impl AuthoredPrStore {
    /// A store that is never written to disk.
    pub fn in_memory() -> Self {
        AuthoredPrStore {
            path: None,
            entries: Mutex::new(BTreeMap::new()),
        }
    }

    /// The store under `state_root`. A missing file starts empty; a corrupt
    /// one starts empty too and logs the error class only.
    pub fn open(state_root: &std::path::Path) -> Self {
        let path = state_root.join("authored-pr-links.json");
        let (entries, _) = load_json_checked::<BTreeMap<String, Entry>>(&path);
        AuthoredPrStore {
            path: Some(path),
            entries: Mutex::new(entries),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, Entry>> {
        self.entries.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn persist(&self, entries: &mut BTreeMap<String, Entry>) {
        entries.retain(|_, e| e.link.is_some() || e.told.is_some());
        if entries.len() > MAX_ENTRIES {
            let mut by_age: Vec<(DateTime<Utc>, String)> = entries
                .iter()
                .map(|(k, e)| (e.newest().unwrap_or(DateTime::<Utc>::MIN_UTC), k.clone()))
                .collect();
            by_age.sort();
            for (_, k) in by_age.into_iter().take(entries.len() - MAX_ENTRIES) {
                entries.remove(&k);
            }
        }
        if let Some(path) = &self.path {
            if write_private(path, entries).is_err() {
                tracing::warn!("authored-pr links could not be written");
            }
        }
    }

    /// Forget the entries of excluded owners (on load), and write the file
    /// at once so their names do not stay on disk. Returns how many.
    pub fn forget_excluded(&self, excluded: &super::exclude::ExcludedOrgs) -> usize {
        let mut g = self.lock();
        let before = g.len();
        g.retain(|k, _| !excluded.covers_key(k));
        let gone = before - g.len();
        if gone > 0 {
            self.persist(&mut g);
        }
        gone
    }

    pub fn get(&self, key: &str) -> Option<Entry> {
        self.lock().get(key).cloned()
    }

    pub fn link(&self, key: &str, tag: &str, now: DateTime<Utc>) {
        let mut g = self.lock();
        g.entry(key.to_owned()).or_default().link = Some(LinkRecord {
            tag: tag.to_owned(),
            at: now,
        });
        self.persist(&mut g);
    }

    /// Remove the link; `true` when there was one.
    pub fn unlink(&self, key: &str) -> bool {
        let mut g = self.lock();
        let had = g
            .get_mut(key)
            .map(|e| e.link.take().is_some())
            .unwrap_or(false);
        if had {
            self.persist(&mut g);
        }
        had
    }

    pub fn told(&self, key: &str, tag: &str, now: DateTime<Utc>, attention_key: &str) {
        let mut g = self.lock();
        g.entry(key.to_owned()).or_default().told = Some(ToldRecord {
            tag: tag.to_owned(),
            at: now,
            attention_key: attention_key.to_owned(),
        });
        self.persist(&mut g);
    }

    /// Drop the entries of PRs that ended (`ended`), and entries older than
    /// 30 days whose PR is no longer listed (`listed` says whether it is).
    pub fn prune(
        &self,
        now: DateTime<Utc>,
        ended: impl Fn(&str) -> bool,
        listed: impl Fn(&str) -> bool,
    ) {
        let mut g = self.lock();
        let before = g.len();
        g.retain(|k, e| {
            if ended(k) {
                return false;
            }
            let stale = e
                .newest()
                .is_none_or(|t| now - t > Duration::days(MAX_AGE_DAYS));
            !(stale && !listed(k))
        });
        if g.len() != before {
            self.persist(&mut g);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(secs: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000 + secs, 0).unwrap()
    }

    #[test]
    fn a_link_and_a_told_record_survive_a_reload_and_hold_only_their_keys() {
        let dir = tempfile::tempdir().unwrap();
        let store = AuthoredPrStore::open(dir.path());
        let k = key_string("Carefeed/App", 7);
        assert_eq!(k, "carefeed/app#7");
        store.link(&k, "cody", t(0));
        store.told(&k, "cody", t(5), "abc");
        drop(store);
        let again = AuthoredPrStore::open(dir.path());
        let e = again.get(&k).unwrap();
        assert_eq!(e.link.unwrap().tag, "cody");
        assert_eq!(e.told.unwrap().attention_key, "abc");

        let raw: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(dir.path().join("authored-pr-links.json")).unwrap(),
        )
        .unwrap();
        let entry = raw[&k].as_object().unwrap();
        let mut keys: Vec<&str> = entry.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["link", "told"]);
        let mut link_keys: Vec<&str> = entry["link"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        link_keys.sort_unstable();
        assert_eq!(link_keys, ["at", "tag"]);
        let mut told_keys: Vec<&str> = entry["told"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        told_keys.sort_unstable();
        assert_eq!(told_keys, ["at", "attention_key", "tag"]);
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(dir.path().join("authored-pr-links.json"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn unlink_removes_only_the_link_and_a_corrupt_file_starts_empty() {
        let dir = tempfile::tempdir().unwrap();
        let store = AuthoredPrStore::open(dir.path());
        store.link("o/n#1", "a", t(0));
        store.told("o/n#1", "a", t(1), "k");
        assert!(store.unlink("o/n#1"));
        assert!(!store.unlink("o/n#1"));
        let e = store.get("o/n#1").unwrap();
        assert!(e.link.is_none() && e.told.is_some());
        std::fs::write(dir.path().join("authored-pr-links.json"), "{not json").unwrap();
        let bad = AuthoredPrStore::open(dir.path());
        assert!(bad.get("o/n#1").is_none());
    }

    #[test]
    fn ended_prs_and_stale_unlisted_entries_are_dropped_and_there_are_at_most_500() {
        let store = AuthoredPrStore::in_memory();
        store.link("o/n#1", "a", t(0));
        store.link("o/n#2", "a", t(0));
        store.link("o/n#3", "a", t(0));
        let later = t(31 * 24 * 3600);
        store.prune(later, |k| k == "o/n#1", |k| k == "o/n#3");
        assert!(store.get("o/n#1").is_none(), "ended");
        assert!(store.get("o/n#2").is_none(), "stale and unlisted");
        assert!(store.get("o/n#3").is_some(), "stale but still listed");

        for i in 0..520 {
            store.link(&format!("o/n#{}", 1000 + i), "a", t(i));
        }
        assert!(store.lock().len() <= MAX_ENTRIES);
        assert!(store.get("o/n#1000").is_none(), "the oldest went first");
        assert!(store.get("o/n#1519").is_some());
    }
}
