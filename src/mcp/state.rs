//! Shared state threaded through the MCP server and tool handlers.
//!
//! `McpSharedState` is cheaply cloneable (`Arc`-backed) and safe to pass
//! across task boundaries.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::SystemTime;

use tokio::sync::{mpsc, RwLock};

use crate::event::AppEvent;

// ── identity types ─────────────────────────────────────────────────────────────

/// Identity record for a PTY spawned by Nostromo.
///
/// Registered in `McpSharedState::ptys` when a PTY is spawned and removed on
/// `Drop` (or when the view tears down).
#[derive(Debug, Clone)]
pub struct PtyIdentity {
    /// The view that owns this PTY (e.g. `"perri"`, `"fred"`).
    pub view_id: &'static str,
    /// UUID assigned to this specific PTY invocation.
    pub session_id: String,
    /// When the PTY was spawned.
    pub spawned_at: SystemTime,
}

/// Static metadata about a registered view.
#[derive(Debug, Clone)]
pub struct ViewMeta {
    /// Stable lowercase identifier (e.g. `"perri"`).
    pub id: &'static str,
    /// Human-readable title shown in the TUI tab bar.
    pub title: String,
    /// Logical pane ids within this view.
    pub pane_ids: Vec<&'static str>,
}

// ── shared state ───────────────────────────────────────────────────────────────

/// Cheap-clone shared state passed to all MCP tool handlers.
///
/// Backed by `Arc`s so cloning is O(1).
#[derive(Clone)]
pub struct McpSharedState {
    /// For future mutating tools: post an `AppEvent::McpCommand(...)`.
    pub event_tx: mpsc::UnboundedSender<AppEvent>,

    /// Metadata about every registered view.  Populated once at startup.
    pub views_meta: Arc<RwLock<Vec<ViewMeta>>>,

    /// Live PTY registry: `nostromo_pty_id` → `PtyIdentity`.
    ///
    /// Keys are the `NOSTROMO_PTY_ID` env var values injected at spawn time.
    pub ptys: Arc<RwLock<HashMap<String, PtyIdentity>>>,
}

impl McpSharedState {
    pub fn new(event_tx: mpsc::UnboundedSender<AppEvent>) -> Self {
        Self {
            event_tx,
            views_meta: Arc::new(RwLock::new(Vec::new())),
            ptys: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Register a spawned PTY.
    pub async fn register_pty(&self, nostromo_pty_id: String, identity: PtyIdentity) {
        self.ptys.write().await.insert(nostromo_pty_id, identity);
    }

    /// Deregister a PTY (called on PTY drop).
    pub async fn deregister_pty(&self, nostromo_pty_id: &str) {
        self.ptys.write().await.remove(nostromo_pty_id);
    }
}
