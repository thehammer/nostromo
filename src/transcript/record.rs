//! Serde types for Claude Code JSONL session log records.
//!
//! Each line in the session log is one `Record`.  We parse `user` and
//! `assistant` records; everything else is treated as `Other` and discarded.

use serde::{Deserialize, Serialize};

// ── Top-level record ──────────────────────────────────────────────────────────

/// One line from a Claude Code JSONL session log.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Record {
    User {
        message: UserMessage,
        uuid: String,
        timestamp: String,
    },
    Assistant {
        message: AssistantMessage,
        uuid: String,
        timestamp: String,
    },
    /// Every other record type (agent-setting, file-history-snapshot, etc.).
    #[serde(other)]
    Other,
}

// ── User message ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct UserMessage {
    pub content: UserContent,
}

/// User content is either a plain string or a list of content blocks.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum UserContent {
    Text(String),
    Blocks(Vec<ContentBlock>),
}

// ── Assistant message ─────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct AssistantMessage {
    pub content: Vec<ContentBlock>,
    /// `null` while streaming; set to the stop reason when the turn completes.
    pub stop_reason: Option<String>,
    /// Token usage for this turn.  Present once the turn completes; absent
    /// in streaming records.
    #[serde(default)]
    pub usage: Option<Usage>,
}

/// Token counts reported by the Claude API at the end of each assistant turn.
///
/// All fields default to zero via `#[serde(default)]` so that records with
/// partial or missing usage fields parse cleanly.
#[derive(Debug, Default, Deserialize, Clone)]
pub struct Usage {
    #[serde(default)]
    pub input_tokens: u64,
    #[serde(default)]
    pub cache_creation_input_tokens: u64,
    #[serde(default)]
    pub cache_read_input_tokens: u64,
    #[serde(default)]
    pub output_tokens: u64,
}

// ── Content blocks ────────────────────────────────────────────────────────────

/// A single content block inside a user or assistant message.
#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ContentBlock {
    Text {
        text: String,
    },
    Thinking {
        thinking: String,
        signature: Option<String>,
    },
    ToolUse {
        id: String,
        name: String,
        input: serde_json::Value,
    },
    ToolResult {
        tool_use_id: String,
        /// Content is either a string or an array of sub-blocks; we coerce to
        /// string for display purposes.
        #[serde(default)]
        content: ToolResultContent,
    },
    /// Forward-compatible: ignore unknown block types.
    #[serde(other)]
    Unknown,
}

/// Tool result content — can be a plain string, a list of blocks, or absent.
#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(untagged)]
pub enum ToolResultContent {
    Text(String),
    Blocks(Vec<serde_json::Value>),
    #[default]
    Empty,
}

impl ToolResultContent {
    /// Collapse to a display string.
    pub fn as_display(&self) -> String {
        match self {
            Self::Text(s) => s.clone(),
            Self::Blocks(blocks) => {
                // Extract text from the first block if possible.
                blocks
                    .first()
                    .and_then(|b| b.get("text"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("(tool result)")
                    .to_string()
            }
            Self::Empty => String::new(),
        }
    }
}
