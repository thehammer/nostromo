//! Dirty-file watcher — triggers an immediate refresh when a sentinel file
//! appears (the same mechanism used by the bash pane scripts).

use std::path::PathBuf;
use std::time::Duration;

use tokio::sync::mpsc;

const POLL_MS: u64 = 500;

/// Spawn a task that watches `path` for existence.  Each time the file appears
/// the task removes it and sends a unit on `tx`, waking the data source loop.
pub fn spawn_watcher(path: PathBuf, tx: mpsc::UnboundedSender<()>) {
    tokio::spawn(async move {
        loop {
            if path.exists() {
                let _ = tokio::fs::remove_file(&path).await;
                if tx.send(()).is_err() {
                    break;
                }
            }
            tokio::time::sleep(Duration::from_millis(POLL_MS)).await;
        }
    });
}
