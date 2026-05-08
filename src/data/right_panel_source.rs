//! Right-panel data source.
//!
//! Subscribes to `AgentBus`, maintains a per-agent rolling snapshot (last 5
//! tool calls), and emits `AppEvent::RightPanelData` on change.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use tokio::sync::mpsc;
use tracing::warn;

use crate::{agent_bus::AgentBus, event::AppEvent};

/// A snapshot of one agent's recent activity for the right panel.
#[derive(Debug, Clone)]
pub struct RightPanelSnapshot {
    pub task_title: String,
    pub recent_tools: Vec<String>,
    pub open_files: Vec<String>,
    pub total_tokens: u64,
    pub last_activity: DateTime<Utc>,
}

impl RightPanelSnapshot {
    fn new() -> Self {
        Self {
            task_title: String::new(),
            recent_tools: Vec::new(),
            open_files: Vec::new(),
            total_tokens: 0,
            last_activity: Utc::now(),
        }
    }

    fn push_event(&mut self, kind: &str, summary: &str, ts: DateTime<Utc>) {
        self.last_activity = ts;
        self.task_title = summary.to_string();

        self.recent_tools.push(kind.to_string());
        if self.recent_tools.len() > 5 {
            self.recent_tools.remove(0);
        }

        // Track file-like tool calls.
        if matches!(
            kind,
            "file_read" | "file_write" | "read" | "write" | "edit" | "Read" | "Write" | "Edit"
        ) {
            // Use the summary as a rough proxy for the filename.
            let file = summary.split_whitespace().next().unwrap_or(summary);
            if !self.open_files.contains(&file.to_string()) {
                self.open_files.push(file.to_string());
            }
            if self.open_files.len() > 10 {
                self.open_files.remove(0);
            }
        }
    }
}

/// Spawn the right-panel data source.  Returns immediately; the watcher runs
/// on a background tokio task.
pub fn spawn(bus: std::sync::Arc<AgentBus>, tx: mpsc::UnboundedSender<AppEvent>) {
    tokio::spawn(async move {
        let mut rx = bus.subscribe();
        let mut snapshots: HashMap<String, RightPanelSnapshot> = HashMap::new();

        loop {
            match rx.recv().await {
                Ok(ev) => {
                    let snap = snapshots
                        .entry(ev.agent.clone())
                        .or_insert_with(RightPanelSnapshot::new);
                    snap.push_event(&ev.kind, &ev.summary, ev.ts);

                    if tx
                        .send(AppEvent::RightPanelData(snapshots.clone()))
                        .is_err()
                    {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    warn!("right-panel source lagged by {n} events");
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break;
                }
            }
        }
    });
}
