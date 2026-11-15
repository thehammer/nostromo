//! A small memory of the focuses that have been open, so a closed owner's
//! agent and name can be offered again by "Start a session…".
//!
//! `<state_root>/focus-memory.json`: `tag -> { agent_name, project_path, name,
//! last_seen }`, at most 200 tags, forgotten after 90 days. No PR data.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use super::FocusInfo;
use crate::mother::origin::{load_json_checked, write_private};

pub const MAX_TAGS: usize = 200;
pub const MAX_AGE_DAYS: i64 = 90;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Remembered {
    pub agent_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_path: Option<String>,
    #[serde(default)]
    pub name: String,
    pub last_seen: DateTime<Utc>,
}

pub struct FocusMemory {
    path: Option<PathBuf>,
    tags: Mutex<BTreeMap<String, Remembered>>,
}

impl FocusMemory {
    pub fn in_memory() -> Self {
        FocusMemory {
            path: None,
            tags: Mutex::new(BTreeMap::new()),
        }
    }

    pub fn open(state_root: &std::path::Path) -> Self {
        let path = state_root.join("focus-memory.json");
        let (tags, _) = load_json_checked::<BTreeMap<String, Remembered>>(&path);
        FocusMemory {
            path: Some(path),
            tags: Mutex::new(tags),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, Remembered>> {
        self.tags.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Note the open focuses. Writes only when something other than a
    /// `last_seen` within the same hour changed.
    pub fn observe(&self, open: &[FocusInfo], now: DateTime<Utc>) {
        let mut g = self.lock();
        let mut dirty = false;
        for f in open.iter().filter(|f| !f.agent_name.is_empty()) {
            let project_path = f
                .project_path
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned());
            let fresh = Remembered {
                agent_name: f.agent_name.clone(),
                project_path,
                name: f.name.clone(),
                last_seen: now,
            };
            match g.get(&f.tag) {
                Some(old)
                    if old.agent_name == fresh.agent_name
                        && old.project_path == fresh.project_path
                        && old.name == fresh.name
                        && now - old.last_seen < Duration::hours(1) => {}
                _ => {
                    g.insert(f.tag.clone(), fresh);
                    dirty = true;
                }
            }
        }
        let before = g.len();
        g.retain(|_, r| now - r.last_seen <= Duration::days(MAX_AGE_DAYS));
        if g.len() > MAX_TAGS {
            let mut by_age: Vec<(DateTime<Utc>, String)> =
                g.iter().map(|(k, r)| (r.last_seen, k.clone())).collect();
            by_age.sort();
            for (_, k) in by_age.into_iter().take(g.len() - MAX_TAGS) {
                g.remove(&k);
            }
        }
        if dirty || g.len() != before {
            if let Some(path) = &self.path {
                if write_private(path, &*g).is_err() {
                    tracing::warn!("focus memory could not be written");
                }
            }
        }
    }

    pub fn get(&self, tag: &str) -> Option<Remembered> {
        self.lock().get(tag).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn focus(tag: &str, agent: &str) -> FocusInfo {
        FocusInfo {
            tag: tag.into(),
            name: format!("{tag} focus"),
            agent_name: agent.into(),
            session_id: None,
            spawn_cwd: None,
            project_path: Some(PathBuf::from("/tmp/p")),
        }
    }

    #[test]
    fn a_focus_is_remembered_across_a_reload_without_any_pr_data() {
        let dir = tempfile::tempdir().unwrap();
        let now = DateTime::from_timestamp(1_800_000_000, 0).unwrap();
        FocusMemory::open(dir.path()).observe(&[focus("cody", "cody")], now);
        let again = FocusMemory::open(dir.path());
        let r = again.get("cody").unwrap();
        assert_eq!(
            (r.agent_name.as_str(), r.project_path.as_deref()),
            ("cody", Some("/tmp/p"))
        );
        let raw: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(dir.path().join("focus-memory.json")).unwrap(),
        )
        .unwrap();
        let mut keys: Vec<&str> = raw["cody"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        assert_eq!(keys, ["agent_name", "last_seen", "name", "project_path"]);
    }

    #[test]
    fn old_tags_are_forgotten_and_there_are_at_most_200() {
        let m = FocusMemory::in_memory();
        let t0 = DateTime::from_timestamp(1_800_000_000, 0).unwrap();
        m.observe(&[focus("old", "cody")], t0);
        let later = t0 + Duration::days(91);
        m.observe(&[focus("new", "cody")], later);
        assert!(m.get("old").is_none() && m.get("new").is_some());
        let many: Vec<FocusInfo> = (0..230).map(|i| focus(&format!("t{i}"), "cody")).collect();
        m.observe(&many, later);
        assert!(m.lock().len() <= MAX_TAGS);
    }
}
