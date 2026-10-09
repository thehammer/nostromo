//! The daemon's shared view of the Mother job list.
//!
//! One [`JobsFeed`] is created at daemon start-up and handed to everything
//! that reads or writes the list: the 2 s poller, the peek poller, and the
//! MCP server (readers *and* the mutating tools, which publish through it so
//! a `mother.cancel_job` is visible to `mother.list_jobs` immediately instead
//! of after the next poll).

use std::sync::Arc;

use chrono::{DateTime, Utc};
use tokio::sync::watch;

use super::MotherJob;

/// Whether the job list can be trusted.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum MotherSourceState {
    /// No `mother list` has completed yet.
    #[default]
    Loading,
    /// The latest `mother list` succeeded.
    Fresh { updated_at: DateTime<Utc> },
    /// The latest `mother list` failed; the jobs are from an earlier success.
    Stale { reason: String, updated_at: DateTime<Utc> },
    /// `mother list` has never succeeded.
    Error { reason: String },
}

impl MotherSourceState {
    /// The contract's source-state string (`loading|fresh|stale|error`).
    pub fn name(&self) -> &'static str {
        match self {
            Self::Loading => "loading",
            Self::Fresh { .. } => "fresh",
            Self::Stale { .. } => "stale",
            Self::Error { .. } => "error",
        }
    }

    pub fn reason(&self) -> Option<&str> {
        match self {
            Self::Stale { reason, .. } | Self::Error { reason } => Some(reason),
            _ => None,
        }
    }

    pub fn updated_at(&self) -> Option<DateTime<Utc>> {
        match self {
            Self::Fresh { updated_at } | Self::Stale { updated_at, .. } => Some(*updated_at),
            _ => None,
        }
    }
}

/// Publisher + reader handle for the Mother job list. Cheap to clone.
#[derive(Clone)]
pub struct JobsFeed {
    jobs_tx: Arc<watch::Sender<Vec<MotherJob>>>,
    source_tx: Arc<watch::Sender<MotherSourceState>>,
}

impl Default for JobsFeed {
    fn default() -> Self {
        Self::new()
    }
}

impl JobsFeed {
    pub fn new() -> Self {
        Self {
            jobs_tx: Arc::new(watch::channel(Vec::new()).0),
            source_tx: Arc::new(watch::channel(MotherSourceState::Loading).0),
        }
    }

    pub fn jobs_rx(&self) -> watch::Receiver<Vec<MotherJob>> {
        self.jobs_tx.subscribe()
    }

    pub fn source_rx(&self) -> watch::Receiver<MotherSourceState> {
        self.source_tx.subscribe()
    }

    /// Publish a successful `mother list`.
    pub fn publish_jobs(&self, jobs: Vec<MotherJob>) {
        self.jobs_tx.send_replace(jobs);
        self.source_tx
            .send_replace(MotherSourceState::Fresh { updated_at: Utc::now() });
    }

    /// Record a failed `mother list`. The previous jobs stay readable but the
    /// source is `stale` (or `error` if nothing ever succeeded).
    pub fn publish_failure(&self, reason: impl Into<String>) {
        let reason = reason.into();
        let next = match self.source_tx.borrow().updated_at() {
            Some(updated_at) => MotherSourceState::Stale { reason, updated_at },
            None => MotherSourceState::Error { reason },
        };
        self.source_tx.send_replace(next);
    }

    /// Re-list jobs from the CLI and publish the outcome. Returns the jobs on
    /// success.
    pub async fn refresh(&self) -> anyhow::Result<Vec<MotherJob>> {
        match super::list_jobs().await {
            Ok(jobs) => {
                self.publish_jobs(jobs.clone());
                Ok(jobs)
            }
            Err(e) => {
                self.publish_failure(e.to_string());
                Err(e)
            }
        }
    }
}
