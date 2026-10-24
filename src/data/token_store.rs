//! Token-file I/O shared by the Graph and Google clients.
//!
//! Files are written to a temp path and renamed (mode 0600) inside a directory
//! with mode 0700. Logging rule: the path only, never the contents.

use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

use anyhow::{Context, Result};
use serde::{de::DeserializeOwned, Serialize};
use tracing::{debug, warn};

/// Read and parse a token file. `None` when it is missing or malformed.
pub fn load<T: DeserializeOwned>(path: &Path) -> Option<T> {
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&data)
        .map_err(|e| {
            warn!(
                "ignoring malformed token cache at {}: {:?}",
                path.display(),
                e.classify()
            )
        })
        .ok()
}

/// Atomically write a token file (0600 from creation) into a 0700 directory.
///
/// Only directories this call creates are chmod'd to 0700; an existing parent
/// (e.g. `$HOME`) keeps its mode.
pub fn persist<T: Serialize>(path: &Path, tok: &T) -> Result<()> {
    if let Some(parent) = path.parent() {
        let created: Vec<&Path> = parent
            .ancestors()
            .take_while(|p| !p.as_os_str().is_empty() && !p.exists())
            .collect();
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating token cache dir {}", parent.display()))?;
        for dir in created {
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
                .with_context(|| format!("setting permissions on {}", dir.display()))?;
        }
    }

    let data = serde_json::to_string_pretty(tok).context("serialising token")?;

    let tmp = path.with_extension("json.tmp");
    let result = write_tmp_and_rename(&tmp, path, data.as_bytes());
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result?;

    debug!("token cached at {}", path.display());
    Ok(())
}

fn write_tmp_and_rename(tmp: &Path, path: &Path, data: &[u8]) -> Result<()> {
    // A stale temp from a crashed run must not block create_new.
    match std::fs::remove_file(tmp) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e).with_context(|| format!("removing stale {}", tmp.display())),
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(tmp)
        .with_context(|| format!("creating {}", tmp.display()))?;
    file.write_all(data)
        .with_context(|| format!("writing token to {}", tmp.display()))?;
    file.sync_all()
        .with_context(|| format!("syncing {}", tmp.display()))?;
    drop(file);
    std::fs::rename(tmp, path).with_context(|| format!("renaming token file to {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mode(p: &Path) -> u32 {
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    fn scratch() -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "nostromo-token-store-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn existing_parent_keeps_its_mode() {
        let root = scratch();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = root.join("tok.json");
        persist(&path, &serde_json::json!({"a": 1})).unwrap();
        assert_eq!(mode(&root), 0o755);
        assert_eq!(mode(&path), 0o600);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn newly_created_dirs_are_0700() {
        let root = scratch();
        let path = root.join("a").join("b").join("tok.json");
        persist(&path, &serde_json::json!({"a": 1})).unwrap();
        assert_eq!(mode(&root.join("a")), 0o700);
        assert_eq!(mode(&root.join("a").join("b")), 0o700);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn stale_tmp_does_not_break_persist() {
        let root = scratch();
        let path = root.join("tok.json");
        let tmp = path.with_extension("json.tmp");
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o644)
            .open(&tmp)
            .unwrap();
        std::fs::write(&tmp, "stale").unwrap();
        persist(&path, &serde_json::json!({"a": 1})).unwrap();
        assert!(!tmp.exists());
        assert_eq!(mode(&path), 0o600);
        assert!(std::fs::read_to_string(&path).unwrap().contains("\"a\""));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn tmp_is_created_0600() {
        let root = scratch();
        let tmp = root.join("x.json.tmp");
        write_tmp_and_rename(&tmp, &root.join("x.json"), b"{}").unwrap();
        // The renamed file keeps the creation mode; it never had group/other bits.
        assert_eq!(mode(&root.join("x.json")), 0o600);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn failed_write_leaves_no_tmp() {
        let root = scratch();
        // Renaming a file over a non-empty directory fails.
        let path = root.join("tok.json");
        std::fs::create_dir_all(path.join("child")).unwrap();
        assert!(persist(&path, &serde_json::json!({"a": 1})).is_err());
        assert!(!path.with_extension("json.tmp").exists());
        std::fs::remove_dir_all(&root).unwrap();
    }
}
