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

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Arc;

    use super::*;
    use crate::data::perri_queue::PrQueueItem;

    fn pr(repo: &str, number: u64) -> PrSnapshot {
        PrSnapshot {
            pr_number: Some(number),
            repo: repo.to_owned(),
            title: format!("{repo}#{number}"),
            ..Default::default()
        }
    }

    fn prs(entries: &[(&str, PrSnapshot)]) -> PrSnapshots {
        let map: HashMap<String, Arc<PrSnapshot>> = entries
            .iter()
            .map(|(tag, snap)| ((*tag).to_owned(), Arc::new(snap.clone())))
            .collect();
        Arc::new(map)
    }

    fn queue() -> PrQueueSnapshot {
        PrQueueSnapshot {
            generated_at: None,
            items: vec![PrQueueItem {
                repo: "acme/web".into(),
                number: 42,
                title: "feat: add auth".into(),
                author: "alice".into(),
                bucket: "requested".into(),
                new_activity: false,
                url: "https://github.com/acme/web/pull/42".into(),
                ci_state: Default::default(),
                head_sha: "abc123".into(),
                is_bot: false,
            }],
            stale: false,
            error: None,
        }
    }

    /// A `(repo, number)` PR identity.
    type Pr = (String, u64);

    /// `(tag, queue repos, current (repo, number))` — the parts of a frame
    /// these tests compare.
    fn parts(msg: &ServerMsg) -> (String, Vec<Pr>, Option<Pr>) {
        match msg {
            ServerMsg::PerriState {
                tag,
                queue,
                current,
            } => (
                tag.clone(),
                queue.iter().map(|i| (i.repo.clone(), i.number)).collect(),
                current
                    .as_ref()
                    .map(|c| (c.repo.clone(), c.pr_number.unwrap_or_default())),
            ),
            other => panic!("expected PerriState, got {other:?}"),
        }
    }

    #[test]
    fn build_perri_state_addresses_the_frame_to_its_tag_and_carries_that_focus_s_pr() {
        let q = queue();
        let snap = pr("acme/api", 7);

        let (tag, queue_items, current) =
            parts(&build_perri_state("reviewer-two", Some(&q), Some(&snap)));
        assert_eq!(tag, "reviewer-two");
        assert_eq!(queue_items, vec![("acme/web".to_owned(), 42)]);
        assert_eq!(current, Some(("acme/api".to_owned(), 7)));

        let (tag, queue_items, current) = parts(&build_perri_state("perri", None, None));
        assert_eq!(tag, "perri");
        assert!(queue_items.is_empty(), "a None queue is an empty list");
        assert_eq!(current, None, "a focus with no PR carries no current");
    }

    #[test]
    fn perri_state_tags_floors_at_the_builtin_focus_when_nothing_is_known() {
        assert_eq!(
            perri_state_tags(Vec::<String>::new(), &prs(&[])),
            vec![BUILTIN_PERRI_TAG.to_owned()],
            "with no registry and no pins the fleet-wide queue must still have a frame \
             to travel on"
        );
    }

    #[test]
    fn perri_state_tags_is_the_sorted_union_of_registered_and_pinned_focuses() {
        let pinned = prs(&[("zeta", pr("acme/web", 1)), ("alpha", pr("acme/api", 2))]);
        let registry = vec!["mid".to_owned(), "alpha".to_owned(), "no-pr".to_owned()];

        assert_eq!(
            perri_state_tags(registry, &pinned),
            vec!["alpha", "mid", "no-pr", "zeta"],
            "every registered focus — PR or not — plus every pinned one, once each, sorted"
        );
        assert_eq!(
            perri_state_tags(vec!["mid".to_owned()], &prs(&[])),
            vec!["mid"],
            "the builtin floor applies only when there is no focus at all"
        );
    }

    #[test]
    fn perri_states_is_empty_before_anything_has_been_fetched() {
        let (_qtx, queue_rx) = watch::channel(None::<PrQueueSnapshot>);
        let (_ptx, pr_rx) = watch::channel(crate::data::perri_pr::no_prs());
        let provider = WatchPerriStateProvider::new(queue_rx, pr_rx);

        assert!(
            provider
                .perri_states(&["perri".to_owned(), "reviewer-two".to_owned()])
                .is_empty(),
            "no queue and no pins means there is no state to replay — not an empty frame"
        );
    }

    #[test]
    fn perri_states_sends_one_frame_per_focus_each_with_its_own_pr_and_the_shared_queue() {
        let (_qtx, queue_rx) = watch::channel(Some(queue()));
        let (_ptx, pr_rx) = watch::channel(prs(&[
            ("perri", pr("acme/web", 42)),
            ("reviewer-two", pr("acme/api", 7)),
        ]));
        let provider = WatchPerriStateProvider::new(queue_rx, pr_rx);

        let frames: Vec<_> = provider
            .perri_states(&["perri".to_owned(), "reviewer-two".to_owned()])
            .iter()
            .map(parts)
            .collect();
        let fleet_queue = vec![("acme/web".to_owned(), 42)];
        assert_eq!(
            frames,
            vec![
                (
                    "perri".to_owned(),
                    fleet_queue.clone(),
                    Some(("acme/web".to_owned(), 42))
                ),
                (
                    "reviewer-two".to_owned(),
                    fleet_queue,
                    Some(("acme/api".to_owned(), 7))
                ),
            ],
            "one frame per focus, each carrying only its own PR and the same fleet-wide queue"
        );
    }
}
