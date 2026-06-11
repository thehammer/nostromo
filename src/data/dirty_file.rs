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

/// Spawn a task that watches `path` for appearance **without deleting it**.
///
/// Fires (rising edge) each time the file transitions from absent → present.
/// Used to watch append-only signal files such as `approvals.jsonl`, where the
/// consumer is responsible for processing and removing the file atomically.
pub fn spawn_exists_watcher(path: PathBuf, tx: mpsc::UnboundedSender<()>) {
    tokio::spawn(async move {
        let mut last_existed = path.exists();
        loop {
            tokio::time::sleep(Duration::from_millis(POLL_MS)).await;
            let exists_now = path.exists();
            if exists_now && !last_existed && tx.send(()).is_err() {
                break;
            }
            last_existed = exists_now;
        }
    });
}
