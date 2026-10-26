//! Setup state (`setup.json`): state load and save only. The scan, the draft
//! and the confirm actions arrive in later jobs.
//!
//! Loading never fails and never creates anything: a missing or unreadable
//! file is "not set up". Only `save` writes, and only when a caller asks.

use std::path::Path;

use serde::{Deserialize, Serialize};

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
fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
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

fn create_private_dir(dir: &Path) -> std::io::Result<()> {
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
