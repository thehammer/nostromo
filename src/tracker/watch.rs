//! File watching for boards (contract §3.1): a user or another tool edits a
//! board file, the daemon notices, ingests the edit (attributed `File`) and
//! broadcasts the new view.
//!
//! One task per board directory: `notify` on the parent (non-recursive,
//! filtered by file name), a 150 ms debounce, a 1 s `(mtime, len, inode)` stat
//! poll (FSEvents can miss in-place edits) and a 10 s safety poll, the pattern
//! of `data/teri_todos.rs`. The task only *signals*: whether an edit is the
//! daemon's own is decided by the registry from the exact bytes
//! (`TrackerRegistry::ingest_file_change`), so no timing heuristic is involved.
//!
//! [`BoardFs`] is the seam tests use: every board read, write and stat goes
//! through it, so a test changes "the file" and calls
//! `TrackerRegistry::ingest_file_change` without waiting for FSEvents.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Weak;
use std::time::{Duration, SystemTime};

use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::{broadcast, mpsc};

use super::registry::TrackerRegistry;
use crate::ipc::protocol::ServerMsg;

/// Wait for a burst of writes to settle before reading.
pub const DEBOUNCE: Duration = Duration::from_millis(150);
/// How often the stat signature is compared.
pub const STAT_INTERVAL: Duration = Duration::from_secs(1);
/// Read regardless of the signature at least this often.
pub const SAFETY_POLL: Duration = Duration::from_secs(10);

/// `(mtime, len, inode)`: a change in any of them means the file was written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileSignature {
    pub modified: Option<SystemTime>,
    pub len: u64,
    pub inode: u64,
}

/// Every file operation the tracker performs on a board.
pub trait BoardFs: Send + Sync {
    fn read(&self, path: &Path) -> io::Result<Vec<u8>>;
    /// Writes `bytes` so a reader never sees a partial file (temp file in the
    /// same directory, `fsync`, rename).
    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<()>;
    /// `None` when the file doesn't exist.
    fn signature(&self, path: &Path) -> Option<FileSignature>;
    fn create_dir_all(&self, dir: &Path) -> io::Result<()>;

    /// Called after the registry has built a write on top of `path`'s current
    /// bytes and before it checks they are still what is on disk. A test seam
    /// for "the user saved in between"; does nothing in production.
    fn before_commit(&self, _path: &Path) {}

    /// Removes the `.tracker-*.tmp` files a write killed half way left in
    /// `dir`. Does nothing by default.
    fn remove_stale_temps(&self, _dir: &Path) {}
}

/// A temp file this old is not a write in flight.
const STALE_TEMP_AGE: Duration = Duration::from_secs(60);

/// The real file system.
#[derive(Debug, Clone, Copy, Default)]
pub struct RealBoardFs;

impl BoardFs for RealBoardFs {
    fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
        std::fs::read(path)
    }

    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<()> {
        write_atomic(path, bytes)
    }

    fn signature(&self, path: &Path) -> Option<FileSignature> {
        let meta = std::fs::metadata(path).ok()?;
        #[cfg(unix)]
        let inode = std::os::unix::fs::MetadataExt::ino(&meta);
        #[cfg(not(unix))]
        let inode = 0;
        Some(FileSignature {
            modified: meta.modified().ok(),
            len: meta.len(),
            inode,
        })
    }

    fn create_dir_all(&self, dir: &Path) -> io::Result<()> {
        std::fs::create_dir_all(dir)
    }

    fn remove_stale_temps(&self, dir: &Path) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !is_our_temp_name(&name) {
                continue;
            }
            // `DirEntry::metadata` does not follow symlinks: only plain files.
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            let stale = meta
                .modified()
                .ok()
                .and_then(|modified| modified.elapsed().ok())
                .is_some_and(|age| age >= STALE_TEMP_AGE);
            if meta.is_file() && stale {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

const TEMP_PREFIX: &str = ".tracker-";

/// Whether `name` has the exact shape `tempfile` gives our temp files: `.tracker-` + 6 random
/// ASCII alphanumerics + `.tmp`. A user's own `.tracker-notes.tmp` does not match.
fn is_our_temp_name(name: &str) -> bool {
    name.strip_prefix(TEMP_PREFIX)
        .and_then(|rest| rest.strip_suffix(TEMP_SUFFIX))
        .is_some_and(|mid| mid.len() == 6 && mid.bytes().all(|b| b.is_ascii_alphanumeric()))
}
const TEMP_SUFFIX: &str = ".tmp";

/// Temp file in the target's directory, `fsync`, rename over the target.
/// An existing file's permissions are kept.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut tmp = tempfile::Builder::new()
        .prefix(TEMP_PREFIX)
        .suffix(TEMP_SUFFIX)
        .tempfile_in(dir)?;
    tmp.write_all(bytes)?;
    tmp.as_file().sync_all()?;
    if let Ok(meta) = std::fs::metadata(path) {
        let _ = std::fs::set_permissions(tmp.path(), meta.permissions());
    }
    tmp.persist(path).map_err(|e| e.error)?;
    Ok(())
}

/// Where watcher tasks live: the registry keeps one of these once the daemon
/// calls `TrackerRegistry::start_watching`.
pub(crate) struct WatchHost {
    pub registry: Weak<TrackerRegistry>,
    pub tx: broadcast::Sender<ServerMsg>,
    /// Directories that already have a task.
    pub dirs: HashSet<PathBuf>,
}

/// Starts the watcher task for `dir` (a board's parent directory). Needs a
/// running tokio runtime.
pub(crate) fn spawn_dir_watcher(
    registry: Weak<TrackerRegistry>,
    tx: broadcast::Sender<ServerMsg>,
    dir: PathBuf,
) {
    tokio::spawn(run_dir(registry, tx, dir));
}

async fn run_dir(registry: Weak<TrackerRegistry>, tx: broadcast::Sender<ServerMsg>, dir: PathBuf) {
    let (wake_tx, mut wake_rx) = mpsc::unbounded_channel::<()>();
    let mut watcher = watch_dir(&dir, wake_tx.clone());
    // Last signature seen per board file in this directory.
    let mut seen: HashMap<PathBuf, Option<FileSignature>> = HashMap::new();
    let mut last_read = tokio::time::Instant::now();
    let mut force = true;
    loop {
        let Some(reg) = registry.upgrade() else {
            return;
        };
        let paths = reg.boards_in_dir(&dir);
        for path in paths {
            let now_sig = reg.board_signature(&path);
            let changed = seen.get(&path) != Some(&now_sig);
            if changed || force {
                seen.insert(path.clone(), now_sig);
                if reg.ingest_file_change(&path) {
                    reg.flush(&tx);
                }
            }
        }
        seen.retain(|path, _| reg.is_board(path));
        drop(reg);
        if force {
            last_read = tokio::time::Instant::now();
        }
        force = false;

        tokio::select! {
            woken = wake_rx.recv() => {
                if woken.is_none() { return; }
                // Let a burst of writes settle, then read once.
                tokio::time::sleep(DEBOUNCE).await;
                while wake_rx.try_recv().is_ok() {}
                force = true;
            }
            _ = tokio::time::sleep(STAT_INTERVAL) => {
                if last_read.elapsed() >= SAFETY_POLL {
                    force = true;
                }
            }
        }
        if watcher.is_none() {
            // The directory did not exist yet (or the watch failed): try again.
            watcher = watch_dir(&dir, wake_tx.clone());
        }
    }
}

/// Watches `dir`. `None` if it can't be watched yet; the stat poll keeps the
/// board fresh meanwhile.
fn watch_dir(dir: &Path, wake: mpsc::UnboundedSender<()>) -> Option<RecommendedWatcher> {
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(event) = res else { return };
        if matches!(event.kind, EventKind::Access(_) | EventKind::Other) {
            return;
        }
        // Boards are `.md` files; the daemon's own temp files are not.
        let relevant = event
            .paths
            .iter()
            .any(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("md")));
        if relevant {
            let _ = wake.send(());
        }
    })
    .ok()?;
    watcher.watch(dir, RecursiveMode::NonRecursive).ok()?;
    Some(watcher)
}

#[cfg(test)]
mod temp_name_tests {
    use super::is_our_temp_name;

    #[test]
    fn only_the_exact_tempfile_shape_is_ours() {
        assert!(is_our_temp_name(".tracker-aB3xY9.tmp"));
        for not_ours in [".tracker-notes.tmp", ".tracker-.tmp", ".tracker-aB3xY9z.tmp", ".tracker-aB3x_9.tmp", "tracker-aB3xY9.tmp", ".tracker-aB3xY9.tmp.bak"] {
            assert!(!is_our_temp_name(not_ours), "{not_ours}");
        }
    }
}
