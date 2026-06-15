//! MCP command types bridging the MCP server → main event loop.
//!
//! The MCP server runs on a Tokio task; mutable UI state lives on the main
//! event loop in `src/app.rs`.  Mutating tools construct an `McpCommand`,
//! attach a `tokio::sync::oneshot` reply channel, and send it through
//! `McpSharedState::event_tx` as `AppEvent::McpCommand(...)`.  The main loop
//! dispatches each command synchronously and replies via the oneshot.
//!
//! Tool handlers await the reply with a 5-second timeout; if the event loop
//! does not reply in time they return `"event_loop_timeout"`.
//!
//! Phase 4 additions: `Notify`, `RegisterStatusSegment`, `ClearStatusSegment`.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tokio::sync::oneshot;

use crate::ipc::protocol::PrListItem;

// ── notification level ────────────────────────────────────────────────────────

/// Severity level for a `nostromo.notify` call.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum NotifyLevel {
    #[default]
    Info,
    Warn,
    Error,
}

// ── reply type ────────────────────────────────────────────────────────────────

/// Result type threaded through every command's reply channel.
///
/// `Ok(T)` on success; `Err(String)` carries a stable machine-readable code
/// (snake_case) optionally followed by `: <human detail>`.
pub type McpReply<T> = Result<T, String>;

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

// ── minimal Mother job lite ───────────────────────────────────────────────────

/// Minimal job record returned by `mother.enqueue_job`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MotherJobLite {
    pub id: String,
    pub title: String,
    pub status: String,
}

// ── command enum ──────────────────────────────────────────────────────────────

/// Commands from MCP tool handlers to the main event loop.
///
/// Boxed at the `AppEvent` level so `AppEvent` stays small.
#[derive(Debug)]
pub enum McpCommand {
    // ── Pane / view mutations ─────────────────────────────────────────────────
    /// Set the focused pane within a view, or switch the active view.
    SetPaneFocus {
        view_id: String,
        pane_id: String,
        reply: oneshot::Sender<McpReply<()>>,
    },

    /// Apply a content mutation to a specific pane.
    SetPaneContent {
        view_id: String,
        pane_id: String,
        content: PaneContent,
        reply: oneshot::Sender<McpReply<()>>,
    },

    /// Update a view's pane-split ratios.
    SetPaneLayout {
        view_id: String,
        ratios: serde_json::Value,
        reply: oneshot::Sender<McpReply<()>>,
    },

    /// Switch the globally-active view tab.
    SwitchActiveView {
        view_id: String,
        reply: oneshot::Sender<McpReply<()>>,
    },

    // ── Perri-specific mutations ───────────────────────────────────────────────
    /// Load a PR into Perri's diff pane.
    PerriLoadPr {
        number: u64,
        repo: String,
        highlights: Option<String>,
        reply: oneshot::Sender<McpReply<()>>,
    },

    /// Clear the currently-loaded PR from Perri.
    PerriClearCurrentPr {
        reply: oneshot::Sender<McpReply<()>>,
    },

    /// Read Perri's selected queue index.
    GetPerriSelectedIndex {
        reply: oneshot::Sender<McpReply<usize>>,
    },

    /// Set Perri's selected queue index.
    SetPerriSelectedIndex {
        index: usize,
        reply: oneshot::Sender<McpReply<()>>,
    },

    // ── Mother job control ────────────────────────────────────────────────────
    /// Enqueue a plan file; returns a minimal job record.
    MotherEnqueue {
        plan_path: PathBuf,
        reply: oneshot::Sender<McpReply<MotherJobLite>>,
    },

    /// Cancel a running/queued/awaiting job.
    MotherCancel {
        job_id: String,
        reply: oneshot::Sender<McpReply<()>>,
    },

    /// Archive terminal-state jobs (by id or by age).
    MotherArchive {
        job_id: String,
        reply: oneshot::Sender<McpReply<()>>,
    },

    /// Resume an `awaiting` job with the operator's answer.
    MotherResume {
        job_id: String,
        answer: String,
        reply: oneshot::Sender<McpReply<()>>,
    },

    /// In-place retry a failed/cancelled job by id (broker `retry` command).
    MotherRetry {
        job_id: String,
        reply: oneshot::Sender<McpReply<()>>,
    },

    // ── Phase 4: notifications & status segments ──────────────────────────────
    /// Post a transient status-bar toast.  Fades after 5 s.
    Notify {
        message: String,
        level: NotifyLevel,
        /// Optional view id requesting the notification (informational only).
        source_view: Option<String>,
        reply: oneshot::Sender<McpReply<()>>,
    },

    /// Register or update a per-view status-bar segment.
    RegisterStatusSegment {
        view_id: String,
        segment_id: String,
        text: String,
        /// Named color: `"red"`, `"amber"`, `"sage"`, `"blue"`, `"muted"` or
        /// a 6-digit hex string like `"#ff8800"`.
        color: Option<String>,
        reply: oneshot::Sender<McpReply<()>>,
    },

    /// Remove a per-view status-bar segment.
    ClearStatusSegment {
        view_id: String,
        segment_id: String,
        reply: oneshot::Sender<McpReply<()>>,
    },
}
