//! Live transcript reader for Claude Code JSONL session logs.
//!
//! Claude Code appends one JSON record per line to
//! `~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl` during a live
//! session.  This module provides:
//!
//! - `path` — helpers to compute the log path from `(cwd, session_id)`.
//! - `record` — serde types for the JSONL record schema.
//! - `snapshot` — `TranscriptEntry` and `TranscriptSnapshot` types.
//! - `reader` — `TranscriptReader` that tails the file and publishes
//!   `TranscriptSnapshot` updates on a `tokio::sync::watch` channel.

pub mod path;
pub mod reader;
pub mod record;
pub mod snapshot;

pub use path::find_latest_session_id_for_cwd;
pub use reader::TranscriptReader;
pub use snapshot::{TranscriptEntry, TranscriptSnapshot};
