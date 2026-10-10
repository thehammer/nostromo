//! Teri todos native data source — reads `~/.teri/teri.db` (SQLite WAL) for
//! active todos and pushes snapshots to a watch channel. The directory is
//! watched (`notify`, 250 ms debounce) and the db and its `-wal` are stat'ed
//! every 500 ms (a long-lived writer's appends do not always raise a file-system
//! event), so a change by Teri's CLI shows up well within 5 s; a full re-read
//! every 10 s covers anything else.
//!
//! The database is owned by Teri's external Claude plugin; nostromo reads it
//! strictly read-only. A missing DB file means Teri was never set up: it is
//! reported as `not_configured` (not an error, and not a bare empty list), so
//! consumers can tell "Teri isn't set up" from both "no todos" and "failed".
//! The snapshot never carries the database path.

use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Utc};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use rusqlite::{Connection, OpenFlags};
use tokio::sync::{mpsc, watch};
use tracing::warn;

const DEBOUNCE: Duration = Duration::from_millis(250);
const SAFETY_POLL: Duration = Duration::from_secs(10);
/// How often the db and `-wal` are stat'ed for a change the watch missed.
const STAT_INTERVAL: Duration = Duration::from_millis(500);

#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct TeriTodosSnapshot {
    pub generated_at: Option<DateTime<Utc>>,
    pub items: Vec<TeriTodo>,
    pub stale: bool,
    pub error: Option<String>,
    /// True when Teri has no database yet (a user who never set Teri up).
    /// That is an empty state, not a failure: `error` stays `None`.
    #[serde(default)]
    pub not_configured: bool,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct TeriTodo {
    pub id: i64,
    pub title: String,
    pub status: String,           // "open" | "in_progress" | "blocked"
    pub priority: u8,             // 1..=5
    pub due_date: Option<String>, // ISO date as stored
    pub jira_key: Option<String>,
    /// Free-text notes on the todo (searchable and shown in the detail view).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
}

impl TeriTodosSnapshot {
    /// Same todos and same health, ignoring when it was read. Used to avoid
    /// republishing an unchanged poll.
    fn same_content(&self, other: &Self) -> bool {
        self.items == other.items
            && self.stale == other.stale
            && self.error == other.error
            && self.not_configured == other.not_configured
    }
}

pub struct TeriTodosNativeSource;

impl TeriTodosNativeSource {
    /// Watch `~/.teri/teri.db`.
    pub fn spawn() -> watch::Receiver<Option<TeriTodosSnapshot>> {
        Self::spawn_at(db_path())
    }

    /// Watch the Teri database at `path` (tests point this at a temp file).
    pub fn spawn_at(path: PathBuf) -> watch::Receiver<Option<TeriTodosSnapshot>> {
        let (tx, rx) = watch::channel(None);
        tokio::spawn(async move {
            run(path, tx).await;
        });
        rx
    }
}

fn db_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".teri").join("teri.db")
}

async fn run(path: PathBuf, tx: watch::Sender<Option<TeriTodosSnapshot>>) {
    let (wake_tx, mut wake_rx) = mpsc::unbounded_channel::<()>();
    let mut watcher = watch_db_dir(&path, wake_tx.clone());
    loop {
        // Taken before the read, so a write that lands during it is seen next time.
        let seen = stat_signature(&path);
        let read_path = path.clone();
        let snap = tokio::task::spawn_blocking(move || fetch_once(read_path))
            .await
            .unwrap_or_else(|join_err| TeriTodosSnapshot {
                generated_at: Some(Utc::now()),
                items: vec![],
                stale: true,
                error: Some(format!("join error: {join_err}")),
                not_configured: false,
            });
        tx.send_if_modified(|current| match current {
            Some(prev) if prev.same_content(&snap) => false,
            _ => {
                *current = Some(snap);
                true
            }
        });

        let read_at = tokio::time::Instant::now();
        loop {
            tokio::select! {
                woken = wake_rx.recv() => {
                    if woken.is_none() { return; }
                    // Let a burst of writes settle, then read once.
                    tokio::time::sleep(DEBOUNCE).await;
                    while wake_rx.try_recv().is_ok() {}
                    break;
                }
                _ = tokio::time::sleep(STAT_INTERVAL) => {
                    if stat_signature(&path) != seen || read_at.elapsed() >= SAFETY_POLL { break; }
                }
            }
        }
        if watcher.is_none() {
            // `~/.teri` did not exist yet (or the watch failed): try again.
            watcher = watch_db_dir(&path, wake_tx.clone());
        }
    }
}

/// `(modified, length)` of the db and its `-wal`. A change here means a write
/// happened. The file watch alone is not enough: a connection that stays open
/// (as Teri's tooling may keep one) appends to the `-wal` without the
/// file-system event stream reporting it.
fn stat_signature(db: &Path) -> [Option<(std::time::SystemTime, u64)>; 2] {
    let stat = |p: &Path| std::fs::metadata(p).ok().and_then(|m| Some((m.modified().ok()?, m.len())));
    let mut wal = db.as_os_str().to_owned();
    wal.push("-wal");
    [stat(db), stat(Path::new(&wal))]
}

/// Watch the directory holding the db (and its `-wal`). `None` if it cannot
/// be watched yet; the stat check keeps the data fresh meanwhile.
fn watch_db_dir(db: &Path, wake: mpsc::UnboundedSender<()>) -> Option<RecommendedWatcher> {
    let dir = db.parent()?;
    // FSEvents reports real paths: resolve symlinks (e.g. /tmp -> /private/tmp) first.
    let dir = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    let file_name = db.file_name()?.to_string_lossy().into_owned();
    let wal_name = format!("{file_name}-wal");
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(event) = res else { return };
        if matches!(event.kind, EventKind::Access(_) | EventKind::Other) {
            return;
        }
        let relevant = event.paths.iter().any(|p| {
            p.file_name().is_some_and(|n| n == file_name.as_str() || n == wal_name.as_str())
        });
        if relevant {
            let _ = wake.send(());
        }
    })
    .ok()?;
    watcher.watch(&dir, RecursiveMode::NonRecursive).ok()?;
    Some(watcher)
}

fn fetch_once(path: PathBuf) -> TeriTodosSnapshot {
    if !path.exists() {
        return TeriTodosSnapshot {
            generated_at: Some(Utc::now()),
            items: vec![],
            stale: false,
            error: None,
            not_configured: true,
        };
    }
    match query_todos(&path) {
        Ok(items) => TeriTodosSnapshot {
            generated_at: Some(Utc::now()),
            items,
            stale: false,
            error: None,
            not_configured: false,
        },
        Err(e) => {
            warn!("teri todos query failed: {e:#}");
            TeriTodosSnapshot {
                generated_at: Some(Utc::now()),
                items: vec![],
                stale: true,
                error: Some(e.to_string()),
                not_configured: false,
            }
        }
    }
}

fn query_todos(path: &PathBuf) -> rusqlite::Result<Vec<TeriTodo>> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    conn.execute_batch("PRAGMA query_only = ON;")?;

    let mut stmt = conn.prepare(
        "SELECT id, title, status, priority, due_date, jira_key, body
         FROM todos
         WHERE status IN ('open','in_progress','blocked')
           AND (snoozed_until IS NULL OR snoozed_until < datetime('now'))
         ORDER BY priority ASC,
                  CASE WHEN due_date IS NULL THEN 1 ELSE 0 END,
                  due_date ASC",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(TeriTodo {
            id: r.get(0)?,
            title: r.get(1)?,
            status: r.get(2)?,
            priority: r.get::<_, i64>(3)? as u8,
            due_date: r.get(4)?,
            jira_key: r.get(5)?,
            body: r.get(6)?,
        })
    })?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_database_is_not_configured_not_an_error_and_leaks_no_path() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join(".teri").join("teri.db");

        let snap = fetch_once(missing);

        assert!(snap.not_configured, "a user with no Teri db is 'not configured'");
        assert_eq!(snap.error, None, "not an error");
        assert!(!snap.stale);
        assert!(snap.items.is_empty());
        let wire = serde_json::to_string(&snap).unwrap();
        let dir_str = dir.path().to_string_lossy();
        assert!(
            !wire.contains(dir_str.as_ref()),
            "no field may carry the db path ({dir_str}): {wire}"
        );
    }

    #[test]
    fn a_present_but_corrupt_database_is_still_a_stale_error_not_not_configured() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("teri.db");
        std::fs::write(&path, vec![0xAB_u8; 4096]).unwrap();

        let snap = fetch_once(path);

        assert!(!snap.not_configured, "a corrupt db is a failure, not an empty state");
        assert!(snap.stale, "{snap:?}");
        assert!(snap.error.is_some(), "{snap:?}");
        assert!(snap.items.is_empty());
    }
}
