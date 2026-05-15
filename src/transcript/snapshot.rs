//! `TranscriptEntry` and `TranscriptSnapshot` — the output types of the reader.

use std::path::PathBuf;
use std::sync::Arc;

/// One decoded entry from the transcript.
#[derive(Debug, Clone)]
pub enum TranscriptEntry {
    /// A message sent by the user.
    UserMessage(String),
    /// Plain text from an assistant response.
    AssistantText(String),
    /// A thinking block (extended reasoning).
    Thinking(String),
    /// A tool invocation.
    ToolUse {
        name: String,
        input: serde_json::Value,
    },
    /// The result returned to a tool call.
    ToolResult {
        tool_use_id: String,
        content: String,
    },
    /// Separator emitted after each complete assistant turn.
    TurnEnd,
}

/// Immutable snapshot of the full transcript decoded so far.
///
/// Cloning is cheap — entries are behind an `Arc`.
#[derive(Debug, Clone)]
pub struct TranscriptSnapshot {
    pub entries: Arc<Vec<TranscriptEntry>>,
    pub path: PathBuf,
    pub session_id: String,
}

impl TranscriptSnapshot {
    /// Returns the list of entry indices the cursor can land on.
    ///
    /// - `TurnEnd` entries are always skipped (they are visual separators, not
    ///   navigable content).
    /// - `Thinking` entries are included only when `show_thinking` is `true`.
    pub fn navigable_entries(&self, show_thinking: bool) -> Vec<usize> {
        self.entries
            .iter()
            .enumerate()
            .filter_map(|(i, e)| match e {
                TranscriptEntry::TurnEnd => None,
                TranscriptEntry::Thinking(_) if !show_thinking => None,
                _ => Some(i),
            })
            .collect()
    }
}
