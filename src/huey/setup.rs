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

fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)
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
}
