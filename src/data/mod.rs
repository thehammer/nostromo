//! Data source abstraction and concrete implementations.
//!
//! Each data source runs in its own tokio task, polls on an interval and on
//! dirty-file wakeup, and pushes snapshots to a `tokio::sync::watch` channel.
//! Views read the latest value on each render tick.

pub mod break_glass;
pub mod daemon_bridge;
pub mod dirty_file;
pub mod fred_calendar;
pub mod fred_calendar_native;
pub mod fred_mailbox;
pub mod fred_mailbox_native;
pub mod github_client;
pub mod graph_client;
pub mod mother_broker_source;
pub mod mother_poll;
pub mod perri_pr;
pub mod perri_pr_native;
pub mod perri_queue;
pub mod perri_queue_native;
pub mod rate_limits;
pub mod rate_limits_watcher;
pub mod right_panel_source;
pub mod teri_todos;

use std::time::Duration;

use anyhow::Result;

/// Trait for a background data source.
pub trait DataSource: Send + 'static {
    /// The snapshot type produced by this source.
    type Snapshot: Clone + Send + Sync + 'static;

    /// Synchronously fetch a fresh snapshot.
    fn refresh(&mut self) -> Result<Self::Snapshot>;

    /// How often to poll in the absence of a dirty-file signal.
    fn poll_interval(&self) -> Duration;
}
