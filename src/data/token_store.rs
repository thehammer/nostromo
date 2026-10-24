//! Token-file I/O shared by the Graph and Google clients.
//!
//! Files are written to a temp path and renamed (mode 0600) inside a directory
//! with mode 0700. Logging rule: the path only, never the contents.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use anyhow::{Context, Result};
use serde::{de::DeserializeOwned, Serialize};
use tracing::{debug, warn};

/// Read and parse a token file. `None` when it is missing or malformed.
pub fn load<T: DeserializeOwned>(path: &Path) -> Option<T> {
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&data)
        .map_err(|e| warn!("ignoring malformed token cache at {}: {:?}", path.display(), e.classify()))
        .ok()
}

/// Atomically write a token file (0600) into a 0700 directory.
pub fn persist<T: Serialize>(path: &Path, tok: &T) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating token cache dir {}", parent.display()))?;
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))
            .with_context(|| format!("setting permissions on {}", parent.display()))?;
    }

    let data = serde_json::to_string_pretty(tok).context("serialising token")?;

    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, &data).with_context(|| format!("writing token to {}", tmp.display()))?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
        .with_context(|| format!("setting permissions on {}", tmp.display()))?;
    std::fs::rename(&tmp, path)
        .with_context(|| format!("renaming token file to {}", path.display()))?;

    debug!("token cached at {}", path.display());
    Ok(())
}
