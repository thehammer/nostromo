//! Shared `ServerMsg::PerriState` builder, plus a [`PerriStateProvider`]
//! implementation over the daemon's live Perri watch channels.
//!
//! `nostromd`'s `run_perri_broadcaster` and the attach-replay path in
//! `server.rs` both need to turn the current queue/per-focus-PR watch
//! snapshots into the same `ServerMsg::PerriState` frames — this module is the
//! one place that does it, so the two paths can't silently drift apart.
//!
//! Both paths are per focus (W7 — D7): one frame per focus the daemon would
//! address, each carrying the fleet-wide queue and only *that* focus's
//! `current`. [`perri_state_tags`] decides which focuses those are, for both.

use std::collections::BTreeSet;

use tokio::sync::watch;

use crate::data::perri_current_pr::BUILTIN_PERRI_TAG;
use crate::data::perri_pr::{PrSnapshot, PrSnapshots};
use crate::data::perri_queue::PrQueueSnapshot;

use super::pane_registry::PerriStateProvider;
use super::protocol::ServerMsg;

/// Build one focus's `ServerMsg::PerriState`.
///
/// `queue` is fleet-wide (D9); `current` is `tag`'s own PR under review, or
/// `None` when that focus has none. A free function so it can be unit-tested
/// without a running daemon, and shared between the broadcaster and
/// [`WatchPerriStateProvider`].
pub fn build_perri_state(
    tag: &str,
    queue_snap: Option<&PrQueueSnapshot>,
    pr_snap: Option<&PrSnapshot>,
) -> ServerMsg {
    ServerMsg::PerriState {
        tag: tag.to_owned(),
        queue: queue_snap.map(|s| s.items.clone()).unwrap_or_default(),
        current: pr_snap.cloned().map(Box::new),
    }
}

/// Every focus a `PerriState` frame could be addressed to: those with a PR
/// under review, plus every focus the daemon knows about (`focus_tags`, the
/// session registry), so a focus with no PR is told *that* rather than being
/// left with whatever it last heard. Sorted, so the frame order is
/// deterministic.
///
/// Lock-free on purpose: the caller collects `focus_tags` from
/// `SessionManager` itself. [`WatchPerriStateProvider`] lives *inside*
/// `SessionManager`, so taking that lock here would deadlock the replay path.
pub fn perri_state_tags(
    focus_tags: impl IntoIterator<Item = String>,
    prs: &PrSnapshots,
) -> Vec<String> {
    let mut tags: BTreeSet<String> = prs.keys().cloned().collect();
    tags.extend(focus_tags);
    // The `queue` half of every `PerriState` frame is fleet-wide (D9), but
    // after W7 it can only travel *on* a per-focus frame. With no focus to
    // address — before a client has pushed a registry, or briefly after one
    // pushes an empty list on reconnect — the fleet would otherwise stop
    // hearing about the queue entirely until the next non-empty push.
    //
    // The built-in `perri` focus exists in every deployment and cannot be
    // removed (`FocusStore.remove` refuses it), so addressing it here is the
    // honest floor rather than an invented recipient.
    if tags.is_empty() {
        tags.insert(BUILTIN_PERRI_TAG.to_owned());
    }
    tags.into_iter().collect()
}

/// [`PerriStateProvider`] over the daemon's live Perri watch channels, for
/// attach replay (f1). `watch::Receiver::borrow` is cheap and never blocks on
/// the poller.
pub struct WatchPerriStateProvider {
    queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
    pr_rx: watch::Receiver<PrSnapshots>,
}

impl WatchPerriStateProvider {
    pub fn new(
        queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
        pr_rx: watch::Receiver<PrSnapshots>,
    ) -> Self {
        Self { queue_rx, pr_rx }
    }
}

impl PerriStateProvider for WatchPerriStateProvider {
    fn perri_states(&self, focus_tags: &[String]) -> Vec<ServerMsg> {
        let queue = self.queue_rx.borrow().clone();
        let prs = self.pr_rx.borrow().clone();
        // Only "nothing has ever been fetched" (no queue and no focus holding
        // a PR) suppresses the replay — a queue-only or PR-only state still
        // replays, matching what the broadcaster's initial send does (a `None`
        // queue maps to an empty vec via `build_perri_state`).
        if queue.is_none() && prs.is_empty() {
            return Vec::new();
        }
        perri_state_tags(focus_tags.iter().cloned(), &prs)
            .into_iter()
            .map(|tag| {
                let pr = prs.get(&tag).map(|s| &**s);
                build_perri_state(&tag, queue.as_ref(), pr)
            })
            .collect()
    }
}
