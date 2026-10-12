//! Persistent model choices: per focus (`focus-models.json`, keyed by daemon
//! tag) and per agent (`model-defaults.json`).
//!
//! The daemon is the single source of truth for a focus's model. Every field
//! is `#[serde(default)]` so an older or partial file still loads, and every
//! write is atomic (temp file + rename) and serialised, so a crash never
//! leaves a truncated store and two writers never drop each other's entries.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Mutex;

use anyhow::Result;
use serde::{Deserialize, Serialize};

use super::ModelTarget;

/// Where a focus's recorded model came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ModelSource {
    /// Chosen for this focus (at creation or by a switch).
    #[default]
    Focus,
    /// The user's per-agent default.
    AgentDefault,
    /// The agent's own `model:` front matter.
    AgentDeclared,
    /// The Claude CLI's default.
    CliDefault,
}

/// What a focus runs on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct FocusModelRecord {
    /// A family alias (`"opus"`) or a full model name (`"claude-sonnet-4-6"`).
    #[serde(default)]
    pub model: String,
    /// Explicit effort level; `None` is the model's default.
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub source: ModelSource,
    /// A switch waiting for the running turn to end. Persisted so a daemon
    /// restart can report that it was dropped.
    #[serde(default)]
    pub pending: Option<ModelTarget>,
}

impl FocusModelRecord {
    pub fn target(&self) -> ModelTarget {
        ModelTarget {
            model: self.model.clone(),
            effort: self.effort.clone(),
        }
    }
}

/// A per-agent default model (the wire type is also the stored shape).
pub type AgentDefault = crate::ipc::protocol::AgentModelDefault;

/// Serialises every read-modify-write of the model stores.
static STORE_LOCK: Mutex<()> = Mutex::new(());

fn load_json<T: serde::de::DeserializeOwned + Default>(path: &Path) -> T {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// [`load_json`] for a read-modify-write: a file that exists but does not
/// parse is moved aside (`<name>.corrupt-<timestamp>`) rather than being
/// overwritten with only the one entry being written, so the other entries
/// can still be recovered by hand.
fn load_json_for_update<T: serde::de::DeserializeOwned + Default>(path: &Path) -> T {
    let Ok(bytes) = std::fs::read(path) else {
        return T::default();
    };
    match serde_json::from_slice(&bytes) {
        Ok(value) => value,
        Err(e) => {
            let aside = path.with_extension(format!(
                "corrupt-{}",
                chrono::Utc::now().format("%Y%m%dT%H%M%SZ")
            ));
            tracing::warn!(
                path = %path.display(),
                aside = %aside.display(),
                "model store does not parse ({e}); moving it aside"
            );
            let _ = std::fs::rename(path, &aside);
            T::default()
        }
    }
}

/// Write `value` as pretty JSON to `path` atomically: a sibling temp file
/// renamed over the target (rename within one directory is atomic).
pub fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let bytes = serde_json::to_vec_pretty(value)?;
    let tmp = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
    std::fs::write(&tmp, &bytes)?;
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.into());
    }
    Ok(())
}

/// Every focus's record.
pub fn load_focus_models(path: &Path) -> BTreeMap<String, FocusModelRecord> {
    load_json(path)
}

/// The record for `tag`, if it has one.
pub fn focus_record(path: &Path, tag: &str) -> Option<FocusModelRecord> {
    load_focus_models(path).remove(tag)
}

/// Apply `change` to `tag`'s record (`None` when it has none) and persist the
/// result; returning `None` from `change` removes the record.
pub fn update_focus_record(
    path: &Path,
    tag: &str,
    change: impl FnOnce(Option<FocusModelRecord>) -> Option<FocusModelRecord>,
) -> Result<Option<FocusModelRecord>> {
    let _guard = STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut all: BTreeMap<String, FocusModelRecord> = load_json_for_update(path);
    let updated = change(all.remove(tag));
    if let Some(record) = &updated {
        all.insert(tag.to_owned(), record.clone());
    }
    write_json_atomic(path, &all)?;
    Ok(updated)
}

/// Clear every persisted `pending` switch, returning `(tag, record before)`
/// for each one cleared.
pub fn clear_all_pending(path: &Path) -> Result<Vec<(String, FocusModelRecord)>> {
    let _guard = STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut all: BTreeMap<String, FocusModelRecord> = load_json_for_update(path);
    let mut cleared = Vec::new();
    for (tag, record) in all.iter_mut() {
        if record.pending.is_some() {
            cleared.push((tag.clone(), record.clone()));
            record.pending = None;
        }
    }
    if !cleared.is_empty() {
        write_json_atomic(path, &all)?;
    }
    Ok(cleared)
}

/// Every per-agent default.
pub fn load_defaults(path: &Path) -> BTreeMap<String, AgentDefault> {
    load_json(path)
}

/// Set (`Some`) or clear (`None`) `agent`'s default.
pub fn set_default(path: &Path, agent: &str, default: Option<AgentDefault>) -> Result<()> {
    let _guard = STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut all: BTreeMap<String, AgentDefault> = load_json_for_update(path);
    match default {
        Some(d) => {
            all.insert(agent.to_owned(), d);
        }
        None => {
            all.remove(agent);
        }
    }
    write_json_atomic(path, &all)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_store_that_does_not_parse_is_moved_aside_not_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("focus-models.json");
        std::fs::write(&path, b"{ \"cody-1\": {\"model\": \"opus\"} TRUNCATED").unwrap();

        update_focus_record(&path, "cody-2", |_| {
            Some(FocusModelRecord { model: "sonnet".into(), ..FocusModelRecord::default() })
        })
        .unwrap();

        let aside: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains("corrupt-"))
            .collect();
        assert_eq!(aside.len(), 1, "the unreadable store is kept for recovery");
        let kept = std::fs::read_to_string(aside[0].path()).unwrap();
        assert!(kept.contains("cody-1"), "{kept}");
        assert_eq!(focus_record(&path, "cody-2").unwrap().model, "sonnet");
    }
}
