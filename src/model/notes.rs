//! The per-session notes ledger: transcript markers ("Model changed to …")
//! that are not messages, kept beside the CLI's own session JSONL so they can
//! be put back in place when a transcript is rebuilt from that JSONL.
//!
//! One file per `claude` session id, one JSON object per line.

use std::io::{Read as _, Seek as _, SeekFrom, Write as _};
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

/// Append one note. The line is flushed to disk before returning (the
/// directory entry too, for a ledger this call creates), and a
/// ledger whose last line was torn by a crash (no trailing newline) gets a
/// newline first, so the fragment stays one unreadable line instead of
/// swallowing this note.
pub fn append(dir: &Path, session_id: &str, note: &LedgerNote) -> Result<()> {
    std::fs::create_dir_all(dir)?;
    let mut line = serde_json::to_string(note)?;
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
        // `sync_data` makes the contents durable, not the file's entry in its
        // directory: without this a power loss can lose the whole new ledger.
        // A directory that can't be fsynced only weakens durability.
        if let Err(e) = std::fs::File::open(dir).and_then(|d| d.sync_all()) {
            tracing::warn!(dir = %dir.display(), "could not fsync the notes directory: {e}");
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn note(after_prompt: u64, text: &str) -> LedgerNote {
        LedgerNote {
            after_prompt,
            kind: NoteKind::ModelChanged,
            text: text.to_owned(),
            ts: Utc::now(),
        }
    }

    #[test]
    fn notes_come_back_in_the_order_they_were_appended() {
        let dir = tempfile::tempdir().unwrap();
        append(dir.path(), "sid-1", &note(0, "first")).unwrap();
        append(dir.path(), "sid-1", &note(2, "second")).unwrap();
        append(dir.path(), "sid-2", &note(1, "someone else's")).unwrap();

        let texts: Vec<String> = load(dir.path(), "sid-1")
            .into_iter()
            .map(|n| n.text)
            .collect();

        assert_eq!(texts, ["first", "second"]);
    }

    #[test]
    fn a_note_appended_after_a_torn_last_line_is_not_merged_into_the_fragment() {
        let dir = tempfile::tempdir().unwrap();
        append(dir.path(), "sid-1", &note(0, "before the crash")).unwrap();
        append(dir.path(), "sid-1", &note(1, "also before")).unwrap();
        let before = load(dir.path(), "sid-1");
        assert_eq!(before.len(), 2);
        // The daemon died halfway through writing the next line: no trailing newline, half the JSON.
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(ledger_path(dir.path(), "sid-1"))
            .unwrap();
        file.write_all(br#"{"after_prompt":2,"kind":"model_chan"#)
            .unwrap();
        drop(file);

        append(dir.path(), "sid-1", &note(2, "after the crash")).unwrap();

        let loaded = load(dir.path(), "sid-1");
        let texts: Vec<&str> = loaded.iter().map(|n| n.text.as_str()).collect();
        assert_eq!(
            texts,
            ["before the crash", "also before", "after the crash"],
            "the earlier notes survive and the new one is not lost inside the torn fragment"
        );
        assert_eq!(&loaded[..2], &before[..], "the earlier notes are unchanged");
    }

    #[test]
    fn appending_to_a_ledger_that_ends_cleanly_adds_no_blank_lines() {
        let dir = tempfile::tempdir().unwrap();
        append(dir.path(), "sid-1", &note(0, "a")).unwrap();
        append(dir.path(), "sid-1", &note(1, "b")).unwrap();

        let raw = std::fs::read_to_string(ledger_path(dir.path(), "sid-1")).unwrap();

        assert_eq!(raw.lines().count(), 2, "{raw:?}");
        assert!(raw.lines().all(|l| !l.trim().is_empty()), "{raw:?}");
        assert!(raw.ends_with('\n'));
    }
}
