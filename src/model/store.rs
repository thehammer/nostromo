//! Persistent model choices: per focus (`focus-models.json`, keyed by daemon
//! tag) and per agent (`model-defaults.json`).
//!
//! The daemon is the single source of truth for a focus's model. Every field
//! is `#[serde(default)]` so an older or partial file still loads, and every
//! write is atomic and durable (temp file, `sync_all`, rename, directory
//! fsync) and serialised, so a crash or power loss never leaves a truncated
//! store and two writers never drop each other's entries.

use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::Path;
use std::sync::Mutex;

use anyhow::Result;
use serde::{Deserialize, Serialize};

use super::ModelTarget;

/// Where a focus's recorded model came from.
///
/// `Focus` and `AgentDefault` are *chosen*: somebody picked that model, so
/// every start passes it to the CLI. `AgentDeclared` and `CliDefault` are
/// *observed*: the model the session reported when nothing had been chosen.
/// An observed record is a note of what ran, not an instruction, so a start
/// passes no `--model` and a later change of the agent's front matter or of
/// the CLI's default is still honoured.
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

impl ModelSource {
    /// Was this model chosen (rather than merely observed)?
    pub fn is_chosen(self) -> bool {
        matches!(self, ModelSource::Focus | ModelSource::AgentDefault)
    }
}

/// A record with no `source` (written before the field existed) is observed.
fn observed_source() -> ModelSource {
    ModelSource::CliDefault
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
    #[serde(default = "observed_source")]
    pub source: ModelSource,
    /// A switch waiting for the running turn to end. Persisted so a daemon
    /// restart can report that it was dropped.
    #[serde(default)]
    pub pending: Option<ModelTarget>,
    /// When the record was last written; the age the garbage collection
    /// goes by. `None` for a record written before the field existed.
    #[serde(default)]
    pub updated_at: Option<chrono::DateTime<chrono::Utc>>,
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

/// Write `value` as pretty JSON to `path` atomically and durably.
pub fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(value)?;
    write_atomic_with(path, |file| file.write_all(&bytes))
}

/// Replace `path` with what `fill` writes, atomically and durably: a sibling
/// temp file is filled, `sync_all`ed, renamed over the target (rename within
/// one directory is atomic) and the directory fsynced, so after a power loss
/// the file is either the old one or the new one, never a truncated one. A
/// failure at any step removes the temp file and leaves the target as it was.
pub(crate) fn write_atomic_with(
    path: &Path,
    fill: impl FnOnce(&mut std::fs::File) -> std::io::Result<()>,
) -> Result<()> {
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty());
    if let Some(parent) = parent {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
    let written = (|| -> std::io::Result<()> {
        let mut file = std::fs::File::create(&tmp)?;
        fill(&mut file)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp, path)
    })();
    if let Err(e) = written {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.into());
    }
    // The rename is done; a directory that can't be fsynced (some
    // filesystems refuse) only weakens durability, it does not undo it.
    let dir = parent.unwrap_or_else(|| Path::new("."));
    if let Err(e) = std::fs::File::open(dir).and_then(|d| d.sync_all()) {
        tracing::warn!(dir = %dir.display(), "could not fsync the directory of {}: {e}", path.display());
    }
    Ok(())
}

/// The files [`write_atomic_with`] is used for, by stem: a leftover is named
/// `<stem>.tmp-<uuid>`.
const STORE_STEMS: [&str; 3] = ["focus-models", "model-defaults", "model-catalog"];

/// How old a temp file must be to count as a leftover: a write in flight (in
/// this process, or another sharing the directory) has a temp file for a few
/// milliseconds, never for this long.
const STALE_TEMP_AGE: std::time::Duration = std::time::Duration::from_secs(60);

/// Remove the leftovers of an interrupted [`write_atomic_with`] (the model
/// store files' `<name>.tmp-…` siblings, at least [`STALE_TEMP_AGE`] old) from
/// `dir`; returns how many were removed. For the start of the daemon.
pub fn sweep_temp_files(dir: &Path) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let mut removed = 0;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let ours = STORE_STEMS.iter().any(|stem| {
            name.strip_prefix(stem)
                .is_some_and(|rest| rest.starts_with(".tmp-"))
        });
        let stale = entry
            .metadata()
            .ok()
            .filter(|m| m.is_file())
            .and_then(|m| m.modified().ok())
            .and_then(|at| at.elapsed().ok())
            .is_some_and(|age| age >= STALE_TEMP_AGE);
        if ours && stale && std::fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    removed
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
    let updated = change(all.remove(tag)).map(|mut record| {
        record.updated_at = Some(chrono::Utc::now());
        record
    });
    if let Some(record) = &updated {
        all.insert(tag.to_owned(), record.clone());
    }
    write_json_atomic(path, &all)?;
    Ok(updated)
}

/// Garbage-collect `focus-models.json`: drop the record of every tag
/// `is_live` rejects whose `updated_at` is before `cutoff`, and stamp `now` on
/// a record that has no `updated_at` (written before the field existed) so it
/// starts ageing. Returns how many records were dropped.
pub fn sweep_focus_records(
    path: &Path,
    now: chrono::DateTime<chrono::Utc>,
    cutoff: chrono::DateTime<chrono::Utc>,
    is_live: impl Fn(&str) -> bool,
) -> Result<usize> {
    let _guard = STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if !path.exists() {
        return Ok(0);
    }
    let mut all: BTreeMap<String, FocusModelRecord> = load_json_for_update(path);
    let before = all.len();
    let mut stamped = false;
    all.retain(|tag, record| match record.updated_at {
        None => {
            record.updated_at = Some(now);
            stamped = true;
            true
        }
        Some(at) => is_live(tag) || at >= cutoff,
    });
    let removed = before - all.len();
    if removed > 0 || stamped {
        write_json_atomic(path, &all)?;
    }
    Ok(removed)
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

/// The model a **new** focus of `agent` starts on, and where that choice came
/// from: `explicit` (the sheet's or the tool's choice) beats the per-agent
/// default in `defaults`, which beats the agent's declared `model:`, which
/// beats the CLI default.
///
/// The CLI default is `(None, None, CliDefault)`: spawn passes no `--model`
/// and the first report records what ran. An explicit effort with no model
/// anywhere to attach it to is dropped (the CLI's own default model has no
/// name to pair it with). Pure: nothing is written.
pub fn resolve_for_new_focus(
    defaults: &Path,
    agent: &str,
    explicit: Option<&ModelTarget>,
) -> (Option<String>, Option<String>, ModelSource) {
    let explicit_model = explicit.map(|t| t.model.trim()).filter(|m| !m.is_empty());
    let explicit_effort = explicit.and_then(|t| t.effort.clone());

    let (model, effort, source) = if let Some(model) = explicit_model {
        (Some(model.to_owned()), explicit_effort, ModelSource::Focus)
    } else if let Some(default) = load_defaults(defaults).remove(agent) {
        (
            Some(default.model),
            explicit_effort.or(default.effort),
            if explicit.is_some() {
                ModelSource::Focus
            } else {
                ModelSource::AgentDefault
            },
        )
    } else if let Some(declared) = super::policy::declared_model(agent) {
        (
            Some(declared),
            explicit_effort,
            if explicit.is_some() {
                ModelSource::Focus
            } else {
                ModelSource::AgentDeclared
            },
        )
    } else {
        (None, None, ModelSource::CliDefault)
    };
    match model {
        Some(_) => (model, effort, source),
        None => (None, None, ModelSource::CliDefault),
    }
}

/// Is `target` shaped like something the CLI could accept: a model name of
/// plain characters (never a flag) and a known effort level? The catalogue
/// check happens at spawn; this only keeps nonsense out of the store and argv.
pub fn is_plausible_choice(target: &ModelTarget) -> bool {
    let model = target.model.as_str();
    let model_ok = !model.is_empty()
        && model.len() <= 64
        && !model.starts_with('-')
        && model
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '[' | ']' | ':'));
    let effort_ok = target
        .effort
        .as_deref()
        .is_none_or(|e| crate::model::cost::EFFORT_LEVELS.contains(&e));
    model_ok && effort_ok
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
            Some(FocusModelRecord {
                model: "sonnet".into(),
                ..FocusModelRecord::default()
            })
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

    // ── durability ────────────────────────────────────────────────────────────

    /// Every `*.tmp-*` sibling in `dir`: what an interrupted atomic write leaves behind.
    fn temp_files(dir: &Path) -> Vec<String> {
        std::fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains(".tmp-"))
            .collect()
    }

    // [seam: store::write_atomic_with]
    #[test]
    fn a_write_that_fails_halfway_leaves_the_old_file_untouched_and_no_temp_file_behind() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("focus-models.json");
        std::fs::write(&path, b"{\"cody-1\": {\"model\": \"opus\"}}").unwrap();
        let before = std::fs::read(&path).unwrap();

        let result = write_atomic_with(&path, |file: &mut std::fs::File| {
            use std::io::Write;
            file.write_all(b"{\"cody-1\": {\"mod")?; // half the bytes, then the disk fills up
            Err(std::io::Error::other("no space left on device"))
        });

        assert!(result.is_err(), "the failure is reported, not swallowed");
        assert_eq!(
            std::fs::read(&path).unwrap(),
            before,
            "the existing file is byte-identical"
        );
        assert_eq!(
            temp_files(dir.path()),
            Vec::<String>::new(),
            "no half-written temp file is left"
        );
    }

    // [seam: store::write_atomic_with]
    #[test]
    fn a_write_that_succeeds_leaves_exactly_the_target_and_creates_missing_directories() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("not-yet").join("focus-models.json");

        write_atomic_with(&path, |file: &mut std::fs::File| {
            use std::io::Write;
            file.write_all(b"{}")
        })
        .unwrap();

        assert_eq!(std::fs::read(&path).unwrap(), b"{}");
        let names: Vec<String> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            names,
            ["focus-models.json"],
            "the temp file was renamed over the target, not copied"
        );
    }

    // [seam: store::write_atomic_with]
    #[test]
    fn a_write_whose_rename_fails_reports_it_and_leaves_no_temp_file() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("focus-models.json");
        std::fs::create_dir(&target).unwrap(); // a directory cannot be replaced by a file
        std::fs::write(target.join("occupant"), b"x").unwrap();

        let result = write_atomic_with(&target, |file: &mut std::fs::File| {
            use std::io::Write;
            file.write_all(b"{}")
        });

        assert!(result.is_err());
        assert_eq!(temp_files(dir.path()), Vec::<String>::new());
        assert!(
            target.join("occupant").exists(),
            "what was there is untouched"
        );
    }

    #[test]
    fn the_json_writer_leaves_only_the_target_behind() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("model-defaults.json");

        write_json_atomic(&path, &BTreeMap::from([("a".to_owned(), 1)])).unwrap();
        write_json_atomic(&path, &BTreeMap::from([("a".to_owned(), 2)])).unwrap();

        assert_eq!(temp_files(dir.path()), Vec::<String>::new());
        let back: BTreeMap<String, i32> =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(back["a"], 2);
    }

    fn names_in(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    /// Make `path` look like it was last written five minutes ago.
    fn age(path: &Path) {
        let then = std::time::SystemTime::now() - std::time::Duration::from_secs(300);
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(then)
            .unwrap();
    }

    // [seam: store::sweep_temp_files]
    #[test]
    fn sweeping_removes_the_leftovers_of_interrupted_writes_and_nothing_else() {
        let dir = tempfile::tempdir().unwrap();
        for leftover in [
            "focus-models.tmp-0b5e1c1e-9d1a-4c1e-8f3a-000000000001",
            "model-defaults.tmp-abc",
            "model-catalog.tmp-",
        ] {
            std::fs::write(dir.path().join(leftover), b"{\"half").unwrap();
            age(&dir.path().join(leftover));
        }
        let keep = [
            "focus-models.json",
            "model-defaults.json",
            "focus-models.corrupt-20260101T000000Z",
            "notes.txt",
            "tmp-but-not-a-leftover",
            // Somebody else's temp files: not ours to delete, old or not.
            "unrelated.tmp-1",
        ];
        for name in keep {
            std::fs::write(dir.path().join(name), b"precious").unwrap();
            age(&dir.path().join(name));
        }

        let removed = sweep_temp_files(dir.path());

        assert_eq!(removed, 3);
        let mut expected: Vec<String> = keep.iter().map(|n| (*n).to_owned()).collect();
        expected.sort();
        assert_eq!(
            names_in(dir.path()),
            expected,
            "only the `.tmp-` leftovers went"
        );
        for name in keep {
            assert_eq!(
                std::fs::read(dir.path().join(name)).unwrap(),
                b"precious",
                "{name} is untouched"
            );
        }
    }

    // [seam: store::sweep_temp_files]
    #[test]
    fn a_temp_file_of_a_write_that_is_in_flight_is_not_swept() {
        let dir = tempfile::tempdir().unwrap();
        let in_flight = dir
            .path()
            .join("focus-models.tmp-0b5e1c1e-9d1a-4c1e-8f3a-000000000002");
        std::fs::write(&in_flight, b"{\"being writ").unwrap();

        assert_eq!(sweep_temp_files(dir.path()), 0);

        assert!(
            in_flight.exists(),
            "a writer in this process or another sharing the directory is still using it"
        );
    }

    // [seam: store::sweep_temp_files]
    #[test]
    fn sweeping_a_clean_or_missing_directory_removes_nothing_and_does_not_fail() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("focus-models.json"), b"{}").unwrap();

        assert_eq!(sweep_temp_files(dir.path()), 0);
        assert_eq!(sweep_temp_files(&dir.path().join("not-yet-created")), 0);
        assert_eq!(names_in(dir.path()), ["focus-models.json"]);
    }

    // [seam: FocusModelRecord::updated_at]
    #[test]
    fn every_write_of_a_record_stamps_when_it_was_made() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("focus-models.json");

        update_focus_record(&path, "cody-1", |_| {
            Some(FocusModelRecord {
                model: "opus".into(),
                ..FocusModelRecord::default()
            })
        })
        .unwrap();
        let stamped = focus_record(&path, "cody-1")
            .unwrap()
            .updated_at
            .expect("stamped by the write");
        let age = chrono::Utc::now() - stamped;
        assert!(
            age.num_seconds().abs() < 10,
            "stamped with now, not copied from the caller: {stamped}"
        );

        // Even a change that hands back the old record unchanged is a write, and is stamped.
        update_focus_record(&path, "cody-1", |r| r).unwrap();
        assert!(focus_record(&path, "cody-1").unwrap().updated_at.unwrap() >= stamped);
        // A record the caller stamped long ago is restamped: the stamp says when the daemon last wrote it.
        let long_ago = chrono::Utc::now() - chrono::Duration::days(400);
        update_focus_record(&path, "cody-1", |r| {
            r.map(|mut r| {
                r.updated_at = Some(long_ago);
                r
            })
        })
        .unwrap();
        let restamped = focus_record(&path, "cody-1").unwrap().updated_at.unwrap();
        assert!(
            restamped > long_ago + chrono::Duration::days(300),
            "{restamped}"
        );
    }

    #[test]
    fn a_record_without_an_updated_at_still_loads() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("focus-models.json");
        std::fs::write(
            &path,
            br#"{"cody-1": {"model": "opus", "source": "focus"}}"#,
        )
        .unwrap();

        let record = focus_record(&path, "cody-1").expect("an older file still loads");

        assert_eq!(record.model, "opus");
    }

    // ── chosen vs observed ────────────────────────────────────────────────────

    // [seam: ModelSource::is_chosen]
    #[test]
    fn only_a_focus_choice_or_an_agent_default_counts_as_chosen() {
        assert!(ModelSource::Focus.is_chosen());
        assert!(ModelSource::AgentDefault.is_chosen());
        assert!(
            !ModelSource::AgentDeclared.is_chosen(),
            "the agent's own front matter is not a choice made for the focus"
        );
        assert!(
            !ModelSource::CliDefault.is_chosen(),
            "what the CLI picked is observed, not chosen"
        );
    }

    #[test]
    fn a_record_with_no_source_is_an_observed_one_so_old_stores_never_pin_a_model() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("focus-models.json");
        std::fs::write(&path, br#"{"cody-1": {"model": "claude-sonnet-4-6"}}"#).unwrap();

        let record = focus_record(&path, "cody-1").unwrap();

        assert_eq!(
            record.source,
            ModelSource::CliDefault,
            "a migrated record was observed, never chosen"
        );
        let from_json: FocusModelRecord = serde_json::from_str(r#"{"model": "opus"}"#).unwrap();
        assert_eq!(from_json.source, ModelSource::CliDefault);
    }

    #[test]
    fn a_record_the_daemon_builds_for_a_choice_defaults_to_a_focus_choice() {
        assert_eq!(FocusModelRecord::default().source, ModelSource::Focus);
        let explicit: FocusModelRecord =
            serde_json::from_str(r#"{"model": "opus", "source": "focus"}"#).unwrap();
        assert_eq!(explicit.source, ModelSource::Focus);
    }
}
