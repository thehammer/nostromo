//! Data source abstraction and concrete implementations.
//!
//! Each data source runs in its own tokio task, polls on an interval and on
//! dirty-file wakeup, and pushes snapshots to a `tokio::sync::watch` channel.
//! `nostromd` and the MCP tools read the latest value on demand.

pub mod dirty_file;
pub mod file_source;
pub mod fred_accounts;
pub mod fred_calendar;
pub mod fred_calendar_native;
pub mod fred_detail;
pub mod fred_mailbox;
pub mod fred_mailbox_native;
pub mod github_client;
pub mod google_calendar;
pub mod google_client;
pub mod google_detail;
pub mod google_mailbox;
pub mod graph_client;
pub mod http_backoff;
pub mod perri_current_pr;
pub mod perri_pr;
pub mod perri_pr_native;
pub mod perri_queue;
pub mod perri_queue_native;
pub mod perri_queue_targeted;
pub mod perri_suppress;
pub mod rate_limits;
pub mod relay_client;
pub mod teri_todos;
pub mod tickets;
pub mod token_store;
pub mod unified_diff;
pub mod work;

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
