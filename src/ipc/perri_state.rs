//! Shared `ServerMsg::PerriState` builder, plus a [`PerriStateProvider`]
//! implementation over the daemon's live Perri watch channels.
//!
//! `nostromd`'s `run_perri_broadcaster` and the attach-replay path in
//! `server.rs` both need to turn the current queue/current-PR watch snapshots
//! into the same `ServerMsg::PerriState` — this module is the one place that
//! does it, so the two paths can't silently drift apart.

use tokio::sync::watch;

use crate::data::perri_pr::PrSnapshot;
use crate::data::perri_queue::PrQueueSnapshot;

use super::pane_registry::PerriStateProvider;
use super::protocol::ServerMsg;

/// Build a `ServerMsg::PerriState` from the current watch-channel snapshots.
///
/// Extracted as a free function so it can be unit-tested without a running
/// daemon, and shared between the broadcaster and [`WatchPerriStateProvider`].
pub fn build_perri_state(
    queue_snap: Option<&PrQueueSnapshot>,
    pr_snap: Option<&PrSnapshot>,
) -> ServerMsg {
    ServerMsg::PerriState {
        queue: queue_snap.map(|s| s.items.clone()).unwrap_or_default(),
        current: pr_snap.cloned().map(Box::new),
    }
}

/// [`PerriStateProvider`] over the daemon's live Perri watch channels, for
/// attach replay (f1). `watch::Receiver::borrow` is cheap and never blocks on
/// the poller.
pub struct WatchPerriStateProvider {
    queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
    pr_rx: watch::Receiver<Option<PrSnapshot>>,
}

impl WatchPerriStateProvider {
    pub fn new(
        queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
        pr_rx: watch::Receiver<Option<PrSnapshot>>,
    ) -> Self {
        Self { queue_rx, pr_rx }
    }
}

impl PerriStateProvider for WatchPerriStateProvider {
    fn perri_state(&self) -> Option<ServerMsg> {
        let queue = self.queue_rx.borrow().clone();
        let pr = self.pr_rx.borrow().clone();
        // Only "nothing has ever been fetched" (both None) suppresses the
        // replay — a queue-only or PR-only snapshot still replays, matching
        // what the initial daemon-start broadcast sends today (a `None`
        // queue maps to an empty vec via `build_perri_state`).
        if queue.is_none() && pr.is_none() {
            return None;
        }
        Some(build_perri_state(queue.as_ref(), pr.as_ref()))
    }
}
