//! Bridges the daemon IPC client into the in-process event bus.
//!
//! When the TUI successfully connects to `nostromd`, this module consumes the
//! `DaemonClient`'s receiver and translates each `ServerMsg` into either:
//!
//! - An `AppEvent` sent on `app_tx` (for Mother state and await transitions), or
//! - A direct `AgentBus::push_external` call (for activity events).

use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::{
    agent_bus::AgentBus,
    event::AppEvent,
    ipc::{DaemonClient, protocol::ServerMsg},
};

/// Consume `client`, dispatch each `ServerMsg` to the appropriate channel, and
/// return immediately (the work happens in a spawned task).
pub fn spawn(
    mut client: DaemonClient,
    app_tx: mpsc::UnboundedSender<AppEvent>,
    bus: Arc<AgentBus>,
) {
    tokio::spawn(async move {
        debug!("daemon bridge task started");
        loop {
            match client.rx.recv().await {
                Some(msg) => dispatch(msg, &app_tx, &bus),
                None => {
                    // Daemon client reader task exited (daemon died / socket closed).
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
        // Control messages — no action needed.
        ServerMsg::Welcome { .. } | ServerMsg::Pong => {}
        ServerMsg::Error { message } => {
            warn!("daemon sent error: {message}");
        }
    }
}
