//! The daemon's shared view of the Mother job list.
//!
//! One [`JobsFeed`] is created at daemon start-up and handed to everything
//! that reads or writes the list: the 2 s poller, the peek poller, and the
//! MCP server (readers *and* the mutating tools, which publish through it so
//! a `mother.cancel_job` is visible to `mother.list_jobs` immediately instead
//! of after the next poll).

use std::sync::atomic::{AtomicU64, Ordering};
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
    /// Tickets handed out by [`JobsFeed::begin`], one per `mother list` started.
    issued: Arc<AtomicU64>,
    /// The newest ticket whose result has been published. A `mother list` that
    /// STARTED before that one finished later and must not overwrite it (the
    /// 2 s poller racing a mutator's refresh would otherwise re-publish the
    /// pre-mutation list).
    applied: Arc<AtomicU64>,
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
            issued: Arc::new(AtomicU64::new(0)),
            applied: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Take a ticket BEFORE starting a `mother list`; pass it to
    /// [`JobsFeed::publish_jobs_at`] / [`JobsFeed::publish_failure_at`].
    pub fn begin(&self) -> u64 {
        self.issued.fetch_add(1, Ordering::SeqCst) + 1
    }

    /// True (and records it) when `ticket` is newer than everything published
    /// so far, i.e. its `mother list` started after the last published one.
    fn claim(&self, ticket: u64) -> bool {
        let mut current = self.applied.load(Ordering::SeqCst);
        loop {
            if ticket <= current {
                return false;
            }
            match self.applied.compare_exchange(current, ticket, Ordering::SeqCst, Ordering::SeqCst) {
                Ok(_) => return true,
                Err(seen) => current = seen,
            }
        }
    }

    /// Publish a successful `mother list` unless a newer one already landed.
    /// Returns whether it was published.
    pub fn publish_jobs_at(&self, ticket: u64, jobs: Vec<MotherJob>) -> bool {
        if !self.claim(ticket) {
            return false;
        }
        self.publish_jobs(jobs);
        true
    }

    /// Record a failed `mother list` unless a newer result already landed.
    pub fn publish_failure_at(&self, ticket: u64, reason: impl Into<String>) -> bool {
        if !self.claim(ticket) {
            return false;
        }
        self.publish_failure(reason);
        true
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
        let ticket = self.begin();
        match super::list_jobs().await {
            Ok(jobs) => {
                self.publish_jobs_at(ticket, jobs.clone());
                Ok(jobs)
            }
            Err(e) => {
                self.publish_failure_at(ticket, e.to_string());
                Err(e)
            }
        }
    }
}

#[cfg(test)]
mod ticket_tests {
    use super::*;

    fn job(id: &str, state: &str) -> MotherJob {
        serde_json::from_value(serde_json::json!({ "id": id, "state": state })).expect("job")
    }

    #[test]
    fn a_list_that_started_earlier_cannot_overwrite_a_later_one() {
        let feed = JobsFeed::new();
        let poller = feed.begin(); // the 2 s poller starts a `mother list` ...
        let mutator = feed.begin(); // ... then a mutator starts its refresh
        // The mutator's (post-mutation) list lands first.
        assert!(feed.publish_jobs_at(mutator, vec![job("j", "cancelled")]));
        // The poller's older (pre-mutation) list finishes later: it must be discarded.
        assert!(!feed.publish_jobs_at(poller, vec![job("j", "running")]));
        let rx = feed.jobs_rx();
        assert_eq!(rx.borrow()[0].state, "cancelled");
    }

    #[test]
    fn a_stale_failure_cannot_demote_a_newer_success() {
        let feed = JobsFeed::new();
        let old = feed.begin();
        let new = feed.begin();
        assert!(feed.publish_jobs_at(new, vec![job("j", "queued")]));
        assert!(!feed.publish_failure_at(old, "database is locked"));
        assert_eq!(feed.source_rx().borrow().name(), "fresh");
    }

    #[test]
    fn tickets_publish_in_order_when_results_arrive_in_order() {
        let feed = JobsFeed::new();
        let a = feed.begin();
        let b = feed.begin();
        assert!(feed.publish_jobs_at(a, vec![job("j", "queued")]));
        assert!(feed.publish_jobs_at(b, vec![job("j", "running")]));
        assert_eq!(feed.jobs_rx().borrow()[0].state, "running");
    }
}
