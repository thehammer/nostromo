//! Teri todos native data source — polls `~/.teri/teri.db` (SQLite WAL) for
//! active todos every 5 s and pushes snapshots to a watch channel.
//!
//! The database is owned by Teri's external Claude plugin; nostromo reads it
//! strictly read-only. A missing DB file means Teri was never set up: it is
//! reported as `not_configured` (not an error, and not a bare empty list), so
//! consumers can tell "Teri isn't set up" from both "no todos" and "failed".
//! The snapshot never carries the database path.

use std::path::PathBuf;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OpenFlags};
use tokio::sync::watch;
use tracing::warn;

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

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct TeriTodo {
    pub id: i64,
    pub title: String,
    pub status: String,           // "open" | "in_progress" | "blocked"
    pub priority: u8,             // 1..=5
    pub due_date: Option<String>, // ISO date as stored
    pub jira_key: Option<String>,
}

pub struct TeriTodosNativeSource;

impl TeriTodosNativeSource {
    pub fn spawn() -> watch::Receiver<Option<TeriTodosSnapshot>> {
        let (tx, rx) = watch::channel(None);
        tokio::spawn(async move {
            run(tx).await;
        });
        rx
    }
}

fn db_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".teri").join("teri.db")
}

async fn run(tx: watch::Sender<Option<TeriTodosSnapshot>>) {
    loop {
        let snap = tokio::task::spawn_blocking(|| fetch_once(db_path()))
            .await
            .unwrap_or_else(|join_err| TeriTodosSnapshot {
                generated_at: Some(Utc::now()),
                items: vec![],
                stale: true,
                error: Some(format!("join error: {join_err}")),
                not_configured: false,
            });
        let _ = tx.send(Some(snap));
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    }
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
        "SELECT id, title, status, priority, due_date, jira_key
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
