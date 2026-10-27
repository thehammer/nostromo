//! Setup state (`setup.json`), the lazy setup scan and the draft interests
//! file. The confirm actions arrive in a later job.
//!
//! Loading never fails and never creates anything: a missing or unreadable
//! file is "not set up". [`scan`] reads the context in memory and writes
//! nothing (D6). Only `save` and [`write_draft`] write, only when a caller
//! asks, and only under the Huey root, never under `~/.claude` (D5).

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::context::{self, profile, ContextEnv, ContextSource, LiveInputs};
use super::interests::{self, InterestSection, Interests};
use super::paths::HueyPaths;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SetupState {
    #[default]
    NotSetUp,
    Confirmed,
}

impl SetupState {
    pub fn as_str(self) -> &'static str {
        match self {
            SetupState::NotSetUp => "not_set_up",
            SetupState::Confirmed => "confirmed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct SetupRecord {
    #[serde(default)]
    pub state: SetupState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confirmed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scanned_at: Option<String>,
}

pub fn load(paths: &HueyPaths) -> SetupRecord {
    std::fs::read_to_string(paths.setup_json())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save(paths: &HueyPaths, record: &SetupRecord) -> std::io::Result<()> {
    let json = serde_json::to_vec_pretty(record)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    write_atomic(&paths.setup_json(), &json)
}

/// Write `bytes` to `path` so that only the owner can read them: the parent
/// directory is 0700 and the file 0600 on unix, both created with those modes
/// (never chmod-after, so there is no window where they are wider). The bytes
/// go to a uniquely named temp file in the same directory, then rename over
/// `path`, so concurrent writers never share a temp file and readers never see
/// a partial file.
pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    create_private_dir(dir)?;
    let file_name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = dir.join(format!(
        ".{file_name}.{}.{}.tmp",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let result = opts
        .open(&tmp)
        .and_then(|mut f| f.write_all(bytes).and_then(|()| f.sync_all()))
        .and_then(|()| std::fs::rename(&tmp, path));
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

pub(crate) fn create_private_dir(dir: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        builder.mode(0o700);
        builder.create(dir)?;
        // A directory that already existed keeps its old mode; tighten it.
        if std::fs::metadata(dir)?.permissions().mode() & 0o777 != 0o700 {
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        }
        Ok(())
    }
    #[cfg(not(unix))]
    builder.create(dir)
}

/// Whether this machine already has an interests file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InterestsStatus {
    /// `<huey root>/interests.md` exists.
    Existing,
    Missing,
    /// Missing, but an older file sits at this path (`~/.claude/huey/interests.md`)
    /// and can be copied in once.
    ImportableFrom(PathBuf),
}

/// One in-flight project as the setup step shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScannedProject {
    pub id: String,
    pub name: String,
    pub how_it_runs: String,
    /// Manifest description or the README's first sentence (≤ 160 chars).
    pub description: Option<String>,
}

/// What the setup scan found. Held in memory only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupScan {
    pub machine: String,
    pub context_sources: Vec<ContextSource>,
    /// In digest order (most recent activity first).
    pub projects: Vec<ScannedProject>,
    pub interests: InterestsStatus,
}

/// Why [`confirm`] said no. Plain English, shown to the reader.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct ConfirmRefused(pub String);

/// Confirm setup: needs an interests file with at least one "What I care
/// about" bullet. On the first confirm writes the default `sources.toml`
/// (never over an existing one), then `setup.json`. Writes only under the
/// Huey root.
pub fn confirm(paths: &HueyPaths, now: DateTime<Utc>) -> Result<(), ConfirmRefused> {
    check_interests_ready(paths)?;
    let failed = |_: std::io::Error| ConfirmRefused("Huey could not save its setup.".to_string());
    if !paths.sources_toml().exists() {
        write_atomic(
            &paths.sources_toml(),
            super::sources::config::default_toml().as_bytes(),
        )
        .map_err(failed)?;
    }
    let mut record = load(paths);
    record.state = SetupState::Confirmed;
    record.confirmed_at = Some(now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
    save(paths, &record).map_err(failed)
}

/// The interests file exists and says what Huey's reader cares about.
fn check_interests_ready(paths: &HueyPaths) -> Result<(), ConfirmRefused> {
    let text = std::fs::read_to_string(paths.interests()).map_err(|_| {
        ConfirmRefused(
            "There is no interests file yet. Open the interests file to write a draft, \
             edit it, then confirm."
                .to_string(),
        )
    })?;
    let has_care_bullet = interests::parse(&text)
        .bullets
        .iter()
        .any(|b| b.section == InterestSection::Care);
    if !has_care_bullet {
        return Err(ConfirmRefused(
            "Your interests file has nothing under \"What I care about, and why\". \
             Add at least one bullet, then confirm."
                .to_string(),
        ));
    }
    Ok(())
}

/// Where an interests file from before D5 may sit.
pub fn legacy_interests(env: &ContextEnv) -> PathBuf {
    env.claude_dir.join("huey").join("interests.md")
}

/// Read the context sources and list what Huey would use (D6). Writes
/// nothing: no profile cache, no state, no draft.
pub fn scan(
    env: &ContextEnv,
    paths: &HueyPaths,
    live: &LiveInputs,
    now: DateTime<Utc>,
) -> SetupScan {
    let existing = std::fs::read_to_string(paths.interests()).ok();
    let legacy = legacy_interests(env);
    let status = if existing.is_some() || paths.interests().exists() {
        InterestsStatus::Existing
    } else if legacy.is_file() {
        InterestsStatus::ImportableFrom(legacy)
    } else {
        InterestsStatus::Missing
    };
    let parsed: Interests = existing
        .as_deref()
        .map(interests::parse)
        .unwrap_or_default();
    let mut inputs = context::gather(env, &parsed, live, None, now);
    inputs.projects.sort_by(|a, b| {
        b.last_activity
            .cmp(&a.last_activity)
            .then_with(|| a.id.cmp(&b.id))
    });
    SetupScan {
        machine: env.machine.clone(),
        context_sources: env.sources(paths),
        projects: inputs
            .projects
            .iter()
            .map(|p| ScannedProject {
                id: p.id.clone(),
                name: p.name.clone(),
                how_it_runs: p.how_it_runs.clone(),
                description: profile::description(&p.root),
            })
            .collect(),
        interests: status,
    }
}

/// The draft interests file for `scan`: the four sections, one "What I care
/// about" bullet per in-flight project, the others empty with a hint.
pub fn draft_text(scan: &SetupScan) -> String {
    let mut out = format!(
        "# Huey interests ({})\n\nEdit this file to steer Huey. Changes apply from the next report.\n",
        scan.machine
    );
    let hint = |section: InterestSection| {
        match section {
        InterestSection::Care => {
            "One bullet per interest, with why it matters. These start as your projects in flight."
        }
        InterestSection::WantMore => "Kinds of news you want more of.",
        InterestSection::WantLess => "Kinds of news you want less of.",
        InterestSection::Ignore => {
            "Topics or projects to drop. Exact terms in backticks are filters: any line with one is dropped."
        }
    }
    };
    for section in InterestSection::ALL {
        out.push_str(&format!(
            "\n## {}\n<!-- {} -->\n",
            section.heading(),
            hint(section)
        ));
        if section == InterestSection::Care {
            for p in &scan.projects {
                match &p.description {
                    Some(d) => out.push_str(&format!("- **{}**: {d}\n", p.name)),
                    None => out.push_str(&format!("- **{}**\n", p.name)),
                }
            }
        }
    }
    out
}

/// Write the draft interests file when none exists. `Ok(true)` when written,
/// `Ok(false)` when a file was already there (it is never overwritten).
pub fn write_draft(paths: &HueyPaths, scan: &SetupScan) -> std::io::Result<bool> {
    if paths.interests().exists() {
        return Ok(false);
    }
    write_atomic(&paths.interests(), draft_text(scan).as_bytes())?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_garbled_is_not_set_up_and_creates_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let paths = HueyPaths::new(dir.path());
        assert_eq!(load(&paths).state, SetupState::NotSetUp);
        assert!(!paths.root().exists());
        std::fs::create_dir_all(paths.root()).unwrap();
        std::fs::write(paths.setup_json(), "{not json").unwrap();
        assert_eq!(load(&paths).state, SetupState::NotSetUp);
    }

    #[test]
    fn save_then_load_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let paths = HueyPaths::new(dir.path());
        let rec = SetupRecord {
            state: SetupState::Confirmed,
            confirmed_at: Some("2026-10-25T12:00:00Z".into()),
            scanned_at: None,
        };
        save(&paths, &rec).unwrap();
        assert_eq!(load(&paths), rec);
    }

    #[cfg(unix)]
    #[test]
    fn save_makes_the_directory_0700_and_the_file_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let paths = HueyPaths::new(dir.path());
        save(&paths, &SetupRecord::default()).unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(paths.root()), 0o700);
        assert_eq!(mode(&paths.setup_json()), 0o600);
    }

    #[cfg(unix)]
    #[test]
    fn save_tightens_an_existing_loose_directory_and_replaces_a_loose_file() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let paths = HueyPaths::new(dir.path());
        std::fs::create_dir_all(paths.root()).unwrap();
        std::fs::set_permissions(paths.root(), std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(paths.setup_json(), "{}").unwrap();
        std::fs::set_permissions(paths.setup_json(), std::fs::Permissions::from_mode(0o644))
            .unwrap();
        save(&paths, &SetupRecord::default()).unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(paths.root()), 0o700);
        assert_eq!(mode(&paths.setup_json()), 0o600);
    }

    #[test]
    fn concurrent_saves_do_not_collide_and_leave_no_temp_files() {
        let dir = tempfile::tempdir().unwrap();
        let paths = HueyPaths::new(dir.path());
        std::thread::scope(|s| {
            for _ in 0..8 {
                s.spawn(|| {
                    for _ in 0..20 {
                        save(&paths, &SetupRecord::default()).unwrap();
                    }
                });
            }
        });
        let names: Vec<_> = std::fs::read_dir(paths.root())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, vec![std::ffi::OsString::from("setup.json")]);
    }
}
