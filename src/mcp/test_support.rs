//! Shared `#[cfg(test)]` state builder for the MCP tool tests.
//!
//! Four `make_state()` test helpers (`pane_sources.rs`,
//! `tools/apply_layout.rs`, `tools/refresh_pane.rs`, `tools/set_pane.rs`) each
//! built a daemon-hosted `McpSharedState` over a throwaway store dir, and each
//! independently leaked its `TempDir` with `std::mem::forget`. This module is
//! the one place that does the leak now; the four helpers delegate to it.

use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;

use crate::ipc::pane_registry::PaneRegistry;
use crate::ipc::protocol::ServerMsg;
use crate::ipc::SessionManager;
use crate::mcp::state::McpSharedState;
use crate::mcp::{DaemonMcpBackend, PerriDaemonState};

pub(crate) struct DaemonTestState {
    pub state: McpSharedState,
    pub bcast_rx: broadcast::Receiver<ServerMsg>,
    pub pane_registry: Arc<Mutex<PaneRegistry>>,
}

/// Build a daemon-hosted `McpSharedState` over a throwaway store dir.
///
/// The `TempDir` is deliberately leaked with `std::mem::forget`: its `Drop`
/// would remove the directory while `PaneRegistry`/`SessionManager` may still
/// write their store files into it, and these are `#[cfg(test)]` helpers
/// whose leak lasts only as long as the test binary. This is the one place in
/// the crate that does it — the four `make_state()` helpers that used to each
/// repeat it now delegate here.
pub(crate) fn daemon_test_state() -> DaemonTestState {
    let tmp = tempfile::TempDir::new().unwrap();
    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        tmp.path().join("panes.json"),
    )));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    std::mem::forget(tmp);

    let (broadcast_tx, bcast_rx) = broadcast::channel(64);
    let backend = DaemonMcpBackend {
        pane_registry: pane_registry.clone(),
        session_mgr,
        broadcast_tx,
        perri: PerriDaemonState::default(),
    };
    let state = McpSharedState::for_daemon(backend);

    DaemonTestState {
        state,
        bcast_rx,
        pane_registry,
    }
}
