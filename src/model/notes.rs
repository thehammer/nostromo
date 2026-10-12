//! The per-session notes ledger: transcript markers ("Model changed to …")
//! that are not messages, kept beside the CLI's own session JSONL so they can
//! be put back in place when a transcript is rebuilt from that JSONL.
//!
//! One file per `claude` session id, one JSON object per line.

use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// What a note is about. Mirrors `TurnBlock::Note.kind` on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoteKind {
    ModelChanged,
    ModelPending,
    ModelFailed,
    ModelMismatch,
    ModelUnavailable,
    ModelRequest,
}

/// One ledger line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LedgerNote {
    /// How many user prompts the session had when the note was made; the note
    /// belongs after the turn of that prompt (0: before the first one).
    pub after_prompt: u64,
    pub kind: NoteKind,
    pub text: String,
    pub ts: DateTime<Utc>,
}

/// The ledger file of `session_id` under `dir`.
pub fn ledger_path(dir: &Path, session_id: &str) -> PathBuf {
    dir.join(format!("{session_id}.jsonl"))
}

/// Append one note.
pub fn append(dir: &Path, session_id: &str, note: &LedgerNote) -> Result<()> {
    std::fs::create_dir_all(dir)?;
    let mut line = serde_json::to_string(note)?;
    line.push('\n');
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ledger_path(dir, session_id))?;
    file.write_all(line.as_bytes())?;
    Ok(())
}

/// Every note of `session_id`, oldest first. Unreadable lines are skipped.
pub fn load(dir: &Path, session_id: &str) -> Vec<LedgerNote> {
    std::fs::read_to_string(ledger_path(dir, session_id))
        .map(|s| {
            s.lines()
                .filter_map(|l| serde_json::from_str(l).ok())
                .collect()
        })
        .unwrap_or_default()
}
