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
        ServerMsg::MotherJobs(jobs) => {
            let _ = app_tx.send(AppEvent::MotherJobs(jobs));
        }
        ServerMsg::MotherStatusline(status) => {
            let _ = app_tx.send(AppEvent::MotherStatusline(status));
        }
        ServerMsg::MotherAwaitDetected(job) => {
            let _ = app_tx.send(AppEvent::AwaitDetected(Box::new(job)));
        }
        // PTY messages are handled by DaemonPtyClient instances directly.
        ServerMsg::PtyOutput { .. }
        | ServerMsg::PtyScrollback { .. }
        | ServerMsg::PtyAttached { .. }
        | ServerMsg::PtySpawned { .. }
        | ServerMsg::PtyExited { .. }
        | ServerMsg::PtyDetach { .. }
        | ServerMsg::PtyListResp { .. } => {
            // Ignored here — PTY consumers subscribe independently.
        }
        // Control messages — no action needed.
        ServerMsg::Welcome { .. } | ServerMsg::Pong => {}
        ServerMsg::Error { message } => {
            warn!("daemon sent error: {message}");
        }
    }
}
