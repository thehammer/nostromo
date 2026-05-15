//! Teri todos native data source — polls `~/.teri/teri.db` (SQLite WAL) for
//! active todos every 5 s and pushes snapshots to a watch channel.
//!
//! The database is owned by Teri's external Claude plugin; nostromo reads it
//! strictly read-only. A missing DB file is treated as "no todos yet" rather
//! than an error.

use std::path::PathBuf;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OpenFlags};
use tokio::sync::watch;
use tracing::warn;

#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct TeriTodosSnapshot {
    pub generated_at: Option<DateTime<Utc>>,
    pub items: Vec<TeriTodo>,
    pub stale: bool,
    pub error: Option<String>,
}

#[derive(Clone, Debug, serde::Serialize)]
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
        };
    }
    match query_todos(&path) {
        Ok(items) => TeriTodosSnapshot {
            generated_at: Some(Utc::now()),
            items,
            stale: false,
            error: None,
        },
        Err(e) => {
            warn!("teri todos query failed: {e:#}");
            TeriTodosSnapshot {
                generated_at: Some(Utc::now()),
                items: vec![],
                stale: true,
                error: Some(e.to_string()),
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
