//! Pane content payload shared by the MCP pane tools.

use serde::{Deserialize, Serialize};

use crate::ipc::protocol::PrListItem;

// ── pane content ──────────────────────────────────────────────────────────────

/// Payload for `set_pane_content` mutations.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PaneContent {
    /// Plain UTF-8 text (markdown, log lines, etc.).
    Text(String),
    /// Structured JSON snapshot (e.g. a diff pane override).
    JsonSnapshot(serde_json::Value),
    /// Typed list of PR queue items rendered by `PerriPRRow`.
    PrList(Vec<PrListItem>),
    /// Transient loading state — agent signals it is refreshing this pane.
    Loading,
    /// Agent encountered an error fetching this pane's content.
    Error(String),
}
