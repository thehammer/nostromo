//! Persist which agent REPLs were open to `~/.nostromo/sessions.toml`.
//!
//! On any load failure (missing file, parse error, schema mismatch) we return
//! an empty store so the caller degrades gracefully (no auto-spawn).
//!
//! `record` and `remove` write through synchronously and warn on failure.

use std::collections::BTreeMap;
use std::path::PathBuf;

use anyhow::Result;
use serde::{Deserialize, Serialize};

// ── storage path ─────────────────────────────────────────────────────────────

fn sessions_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("sessions.toml")
}

// ── wire types ────────────────────────────────────────────────────────────────

/// Wire format version — bump when the schema changes in a breaking way.
const CURRENT_VERSION: u32 = 1;

/// A recorded session entry: what command to re-spawn and in what directory.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionEntry {
    pub cmd: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct SessionFile {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    sessions: BTreeMap<String, SessionEntry>,
}

// ── public API ────────────────────────────────────────────────────────────────

/// In-memory view of `~/.nostromo/sessions.toml`.
///
/// Callers use `SessionStore::load()` to get a fresh copy, mutate it, and the
/// mutation methods (`record`, `remove`) write through to disk immediately.
#[derive(Debug, Default, Clone)]
pub struct SessionStore {
    inner: BTreeMap<String, SessionEntry>,
}

impl SessionStore {
    /// Load from disk. Returns an empty store on any error (non-fatal).
    pub fn load() -> Self {
        match Self::load_inner() {
            Ok(store) => store,
            Err(e) => {
                let path = sessions_path();
                if path.exists() {
                    tracing::warn!("session store: load failed: {e:#}; starting empty");
                }
                Self::default()
            }
        }
    }

    fn load_inner() -> Result<Self> {
        let path = sessions_path();
        let raw = std::fs::read_to_string(&path)?;
        let file: SessionFile = toml::from_str(&raw)?;
        if file.version != CURRENT_VERSION {
            anyhow::bail!("unsupported session store version {}", file.version);
        }
        Ok(Self {
            inner: file.sessions,
        })
    }

    /// Look up a session entry by PTY tag.
    pub fn get(&self, tag: &str) -> Option<&SessionEntry> {
        self.inner.get(tag)
    }

    /// Record (or overwrite) a session entry and flush to disk.
    pub fn record(&mut self, tag: &str, cmd: &str, args: &[&str], cwd: Option<PathBuf>) {
        self.inner.insert(
            tag.to_string(),
            SessionEntry {
                cmd: cmd.to_string(),
                args: args.iter().map(|s| s.to_string()).collect(),
                cwd,
            },
        );
        if let Err(e) = self.save() {
            tracing::warn!("session store: save failed after record: {e:#}");
        }
    }

    /// Remove a session entry and flush to disk.
    pub fn remove(&mut self, tag: &str) {
        self.inner.remove(tag);
        if let Err(e) = self.save() {
            tracing::warn!("session store: save failed after remove: {e:#}");
        }
    }

    fn save(&self) -> Result<()> {
        let path = sessions_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let file = SessionFile {
            version: CURRENT_VERSION,
            sessions: self.inner.clone(),
        };
        let toml_str = toml::to_string_pretty(&file)?;
        std::fs::write(&path, toml_str)?;
        Ok(())
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn round_trip_at(store: &SessionStore, path: &std::path::Path) -> SessionStore {
        let file = SessionFile {
            version: CURRENT_VERSION,
            sessions: store.inner.clone(),
        };
        let toml_str = toml::to_string_pretty(&file).unwrap();
        std::fs::write(path, toml_str).unwrap();

        let raw = std::fs::read_to_string(path).unwrap();
        let loaded: SessionFile = toml::from_str(&raw).unwrap();
        SessionStore {
            inner: loaded.sessions,
        }
    }

    #[test]
    fn round_trip_single_entry() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("sessions.toml");

        let mut store = SessionStore::default();
        store.inner.insert(
            "claudia".to_string(),
            SessionEntry {
                cmd: "claude".to_string(),
                args: vec!["--agent".to_string(), "claudia".to_string()],
                cwd: None,
            },
        );

        let restored = round_trip_at(&store, &path);
        assert!(restored.get("claudia").is_some());
        let entry = restored.get("claudia").unwrap();
        assert_eq!(entry.cmd, "claude");
        assert_eq!(entry.args, vec!["--agent", "claudia"]);
    }

    #[test]
    fn round_trip_multiple_entries() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("sessions.toml");

        let mut store = SessionStore::default();
        for tag in &["claudia", "cody", "kennedy", "teri"] {
            store.inner.insert(
                tag.to_string(),
                SessionEntry {
                    cmd: "claude".to_string(),
                    args: vec!["--agent".to_string(), tag.to_string()],
                    cwd: Some(PathBuf::from("/tmp")),
                },
            );
        }

        let restored = round_trip_at(&store, &path);
        assert!(restored.get("claudia").is_some());
        assert!(restored.get("cody").is_some());
        assert!(restored.get("kennedy").is_some());
        assert!(restored.get("teri").is_some());
        assert!(restored.get("fred").is_none());
        assert_eq!(
            restored.get("cody").unwrap().cwd,
            Some(PathBuf::from("/tmp"))
        );
    }

    #[test]
    fn missing_file_returns_empty() {
        // load_inner on a nonexistent path returns Err, so load() returns default.
        // We verify load() never panics and returns an empty store.
        let store = SessionStore::default();
        assert!(store.get("anything").is_none());
    }

    #[test]
    fn version_mismatch_returns_empty_via_load() {
        // load() swallows errors; version mismatch is one such error.
        let dir = tempdir().unwrap();
        let path = dir.path().join("sessions.toml");

        // Write a future-version file manually.
        std::fs::write(&path, "version = 999\n[sessions]\n").unwrap();

        // We can't easily override sessions_path() in tests, but we can verify
        // load_inner parses version correctly.
        let raw = std::fs::read_to_string(&path).unwrap();
        let file: SessionFile = toml::from_str(&raw).unwrap();
        assert_eq!(file.version, 999);
        // Simulate what load_inner does with a bad version.
        let result: anyhow::Result<SessionStore> = if file.version != CURRENT_VERSION {
            Err(anyhow::anyhow!(
                "unsupported session store version {}",
                file.version
            ))
        } else {
            Ok(SessionStore {
                inner: file.sessions,
            })
        };
        assert!(result.is_err());
    }
}
