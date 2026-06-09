//! Bridges the daemon IPC client into the in-process event bus.
//!
//! When the TUI successfully connects to `nostromd`, this module subscribes to
//! the `DaemonClient`'s broadcast and translates each `ServerMsg` into either:
//!
//! - An `AppEvent` sent on `app_tx` (for Mother state and await transitions), or
//! - A direct `AgentBus::push_external` call (for activity events).

use std::sync::Arc;

use tokio::sync::{broadcast, mpsc};
use tracing::{debug, warn};

use crate::{
    agent_bus::AgentBus,
    event::AppEvent,
    ipc::{protocol::ServerMsg, DaemonClient},
};

/// Subscribe to `client`, dispatch each `ServerMsg` to the appropriate channel,
/// and return immediately (the work happens in a spawned task).
pub fn spawn(client: DaemonClient, app_tx: mpsc::UnboundedSender<AppEvent>, bus: Arc<AgentBus>) {
    let mut rx = client.subscribe();
    tokio::spawn(async move {
        debug!("daemon bridge task started");
        loop {
            match rx.recv().await {
                Ok(msg) => dispatch(msg, &app_tx, &bus),
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    warn!("daemon bridge lagged {n} messages; continuing");
                }
                Err(broadcast::error::RecvError::Closed) => {
                    warn!("daemon bridge: server channel closed; bridge shutting down");
                    break;
                }
            }
        }
        debug!("daemon bridge task done");
    });
}

fn dispatch(msg: ServerMsg, app_tx: &mpsc::UnboundedSender<AppEvent>, bus: &AgentBus) {
    match msg {
        ServerMsg::Activity(ev) => {
            bus.push_external(ev);
        }
        ServerMsg::MotherJobs { jobs } => {
            let _ = app_tx.send(AppEvent::MotherJobs(jobs));
        }
        ServerMsg::MotherStatusline(status) => {
            let _ = app_tx.send(AppEvent::MotherStatusline(status));
        }
        ServerMsg::MotherAwaitDetected(job) => {
            // `job` is already a Box<MotherJob>; AppEvent::AwaitDetected wants
            // exactly that, so pass it through (no re-box).
            let _ = app_tx.send(AppEvent::AwaitDetected(job));
        }
        // PTY messages are handled by DaemonPtyClient instances directly.
        ServerMsg::PtyOutput { .. }
        | ServerMsg::PtyScrollback { .. }
        | ServerMsg::PtyAttached { .. }
        | ServerMsg::PtySpawned { .. }
        | ServerMsg::PtyExited { .. }
        | ServerMsg::PtyDetach { .. }
        | ServerMsg::PtyListResp { .. }
        // PtyIdentity is consumed directly by DaemonPtyClient::spawn_new_with_mcp.
        | ServerMsg::PtyIdentity { .. } => {
            // Ignored here — PTY consumers subscribe independently.
        }
        // Persistent stream-json session messages (protocol v3) are consumed by
        // the Swift thin-client, not the Rust TUI. Ignored here.
        ServerMsg::SessionSpawned { .. }
        | ServerMsg::SessionTurns { .. }
        | ServerMsg::SessionTurnDelta { .. }
        | ServerMsg::SessionState { .. }
        | ServerMsg::SessionPermissionRequest { .. }
        | ServerMsg::SessionExited { .. }
        | ServerMsg::SessionDown { .. }
        | ServerMsg::SessionListResp { .. }
        // Summary updates are consumed by the Swift thin-client.
        | ServerMsg::SessionSummaryUpdate { .. }
        // Focus registry messages are consumed by the Swift/iOS thin-client.
        | ServerMsg::FocusListResp { .. }
        | ServerMsg::FocusRegistryUpdated { .. }
        // Peek snapshots are consumed by Swift clients (iOS + macOS).
        | ServerMsg::MotherPeek { .. }
        // Perri state is consumed by the Swift/iOS thin-client via IPC broadcast.
        | ServerMsg::PerriState { .. }
        // Fred state is consumed by the Swift/iOS thin-client via the fred topic.
        | ServerMsg::FredState { .. }
        // Teri todos are consumed by the Swift thin-clients.
        | ServerMsg::TeriState { .. } => {}
        // DaemonReconnected is handled by individual DaemonPtyClient subscribers.
        ServerMsg::DaemonReconnected => {}
        // Control messages — no action needed.
        ServerMsg::Welcome { .. } | ServerMsg::Pong => {}
        ServerMsg::Error { message } => {
            warn!("daemon sent error: {message}");
        }
    }
}
