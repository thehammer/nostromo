//! Agent activity pub/sub — phase 1 stub.
//!
//! Phase 1: in-memory broadcast with stub events.
//! Phase 2: tails `~/.claude/activity.jsonl` and routes structured events to
//!           the left activity sidebar.

use tokio::sync::broadcast;

/// A single agent activity event.
#[derive(Debug, Clone)]
pub struct AgentEvent {
    /// Agent identifier (e.g. "cody", "fred").
    pub agent: String,
    /// Human-readable description.
    pub message: String,
}

/// Global agent bus.  All views can subscribe to the receiver.
pub struct AgentBus {
    tx: broadcast::Sender<AgentEvent>,
}

impl AgentBus {
    pub fn new() -> Self {
        let (tx, _) = broadcast::channel(256);
        Self { tx }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<AgentEvent> {
        self.tx.subscribe()
    }

    /// Publish an event.  Ignored if there are no subscribers.
    pub fn publish(&self, ev: AgentEvent) {
        let _ = self.tx.send(ev);
    }
}

impl Default for AgentBus {
    fn default() -> Self {
        Self::new()
    }
}
