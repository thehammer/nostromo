//! The per-session batch ledger: which turns of a session were merged frames
//! (`docs/message-queue.md`, "Merging"), kept beside the CLI's own session JSONL
//! so a rebuilt transcript can show each merged turn as separate bubbles.
//!
//! One file per `claude` session id, one JSON object per line. A line carries
//! only the boundary, the part count and a time: never any message text.

use std::io::{Read as _, Seek as _, SeekFrom, Write as _};
use std::path::{Path, PathBuf};

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// One ledger line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BatchRecord {
    pub boundary: String,
    pub count: u32,
    pub ts: DateTime<Utc>,
}

/// The ledger file of `session_id` under `dir`.
pub fn ledger_path(dir: &Path, session_id: &str) -> PathBuf {
    dir.join(format!("{session_id}.jsonl"))
}

/// Append one record, flushed to disk before returning. A ledger whose last
/// line was torn by a crash gets a newline first, so the fragment stays one
/// unreadable line instead of swallowing this record.
pub fn append(dir: &Path, session_id: &str, record: &BatchRecord) -> Result<()> {
    std::fs::create_dir_all(dir)?;
    let mut line = serde_json::to_string(record)?;
    line.push('\n');
    let path = ledger_path(dir, session_id);
    let is_new = !path.exists();
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .append(true)
        .open(&path)?;
    if file.metadata()?.len() > 0 {
        let mut last = [0u8; 1];
        file.seek(SeekFrom::End(-1))?;
        file.read_exact(&mut last)?;
        if last[0] != b'\n' {
            line.insert(0, '\n');
        }
    }
    file.write_all(line.as_bytes())?;
    file.sync_data()?;
    if is_new {
        if let Err(e) = std::fs::File::open(dir).and_then(|d| d.sync_all()) {
            tracing::warn!(dir = %dir.display(), "could not fsync the batches directory: {e}");
        }
    }
    Ok(())
}

/// Every record of `session_id`, oldest first. Unreadable lines are skipped.
pub fn load(dir: &Path, session_id: &str) -> Vec<BatchRecord> {
    std::fs::read_to_string(ledger_path(dir, session_id))
        .map(|s| {
            s.lines()
                .filter_map(|l| serde_json::from_str(l).ok())
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(boundary: &str, count: u32) -> BatchRecord {
        BatchRecord {
            boundary: boundary.to_owned(),
            count,
            ts: Utc::now(),
        }
    }

    #[test]
    fn records_come_back_in_order_per_session() {
        let dir = tempfile::tempdir().unwrap();
        append(dir.path(), "s1", &rec("aa", 2)).unwrap();
        append(dir.path(), "s1", &rec("bb", 3)).unwrap();
        append(dir.path(), "s2", &rec("cc", 4)).unwrap();
        let got: Vec<String> = load(dir.path(), "s1")
            .into_iter()
            .map(|r| r.boundary)
            .collect();
        assert_eq!(got, ["aa", "bb"]);
    }

    #[test]
    fn a_record_after_a_torn_line_is_not_lost_in_the_fragment() {
        let dir = tempfile::tempdir().unwrap();
        append(dir.path(), "s1", &rec("aa", 2)).unwrap();
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(ledger_path(dir.path(), "s1"))
            .unwrap();
        f.write_all(br#"{"boundary":"torn","cou"#).unwrap();
        drop(f);
        append(dir.path(), "s1", &rec("bb", 2)).unwrap();
        let got: Vec<String> = load(dir.path(), "s1")
            .into_iter()
            .map(|r| r.boundary)
            .collect();
        assert_eq!(got, ["aa", "bb"]);
    }

    #[test]
    fn a_missing_ledger_is_empty() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load(dir.path(), "none").is_empty());
    }

    #[test]
    fn the_file_holds_only_boundary_count_and_time() {
        let dir = tempfile::tempdir().unwrap();
        append(dir.path(), "s1", &rec("aa", 2)).unwrap();
        let text = std::fs::read_to_string(ledger_path(dir.path(), "s1")).unwrap();
        let v: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
        let mut keys: Vec<_> = v.as_object().unwrap().keys().cloned().collect();
        keys.sort();
        assert_eq!(keys, ["boundary", "count", "ts"]);
    }
}
