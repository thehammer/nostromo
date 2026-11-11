//! The PR CI feed of bound tracker items (T6): a small poller that runs only
//! while at least one item is bound to a PR (`bind:pr.ci/…`), asking GitHub
//! for each bound PR's check runs every [`POLL_PERIOD`].
//!
//! It is a thin adapter: the fetch is [`fetch_pr_ci`] (conditional GETs, the
//! `perri_pr_native` check-run reader), the result goes to
//! [`BindingHub::apply_ci`]. A failed or cached-after-failure fetch is **not**
//! an observation: the item keeps its last value and `as_of` stays put, so it
//! goes badly stale honestly instead of looking fresh.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use tokio::sync::broadcast;

use super::bindings::{BindingHub, CiObservation};
use super::clock::{Clock, SystemClock};
use super::registry::TrackerRegistry;
use crate::data::github_client::GithubClient;
use crate::data::perri_pr_native::fetch_pr_ci;
use crate::ipc::protocol::ServerMsg;

/// Each bound PR is asked for its CI at most this often.
pub const POLL_PERIOD: Duration = Duration::from_secs(8);

/// How often the loop looks for work (bindings appear between polls).
const LOOP_TICK: Duration = Duration::from_secs(1);

type Caches = Arc<Mutex<HashMap<String, String>>>;

/// Which PR was asked when, and the conditional-GET caches.
pub struct CiPoller {
    hub: BindingHub,
    last_polled: HashMap<(String, u64), DateTime<Utc>>,
    etags: Caches,
    bodies: Caches,
}

impl CiPoller {
    pub fn new(hub: BindingHub) -> CiPoller {
        CiPoller {
            hub,
            last_polled: HashMap::new(),
            etags: Arc::default(),
            bodies: Arc::default(),
        }
    }

    /// Polls every bound PR that was last asked at least [`POLL_PERIOD`]
    /// before `now`. Returns `true` if a bound item's view changed. With
    /// nothing bound it does nothing at all (no request, no caches).
    pub async fn poll_due(&mut self, client: &GithubClient, now: DateTime<Utc>) -> bool {
        let bound = self.hub.bound_prs();
        self.last_polled.retain(|key, _| bound.contains(key));
        if bound.is_empty() {
            self.etags.lock().unwrap_or_else(|e| e.into_inner()).clear();
            self.bodies
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clear();
            return false;
        }
        let period = chrono::Duration::from_std(POLL_PERIOD).unwrap_or_default();
        let mut changed = false;
        for (repo, number) in bound {
            let key = (repo.clone(), number);
            if self
                .last_polled
                .get(&key)
                .is_some_and(|at| now - *at < period)
            {
                continue;
            }
            self.last_polled.insert(key, now);
            match fetch_pr_ci(client, &repo, number, &self.etags, &self.bodies).await {
                Ok(checks) => {
                    changed |=
                        self.hub
                            .apply_ci(&repo, number, &CiObservation::from_checks(&checks), now);
                }
                Err(e) => tracing::debug!("tracker: CI of {repo}#{number} not read: {e:#}"),
            }
        }
        changed
    }
}

/// The daemon's loop: poll what is due, write what the throttle held back,
/// re-check staleness, and send the frames of every board that changed.
/// `github_token_path` is the daemon's configured `hosts.yml` (or `None`).
pub async fn run(
    registry: Arc<TrackerRegistry>,
    tx: broadcast::Sender<ServerMsg>,
    github_token_path: Option<PathBuf>,
) {
    let hub = BindingHub::new(Arc::clone(&registry));
    let mut poller = CiPoller::new(hub.clone());
    let mut client: Option<GithubClient> = None;
    let clock = SystemClock;
    let mut next_client_try = clock.now();
    let mut ticker = tokio::time::interval(LOOP_TICK);
    loop {
        ticker.tick().await;
        if !hub.bound_prs().is_empty() {
            if client.is_none() && clock.now() >= next_client_try {
                client = GithubClient::new(github_token_path.as_deref())
                    .map_err(|e| tracing::warn!("tracker: no GitHub client for PR CI: {e:#}"))
                    .ok();
                next_client_try = clock.now() + chrono::Duration::seconds(60);
            }
            if let Some(client) = &client {
                poller.poll_due(client, clock.now()).await;
            }
        }
        hub.tick();
        registry.flush(&tx);
    }
}
