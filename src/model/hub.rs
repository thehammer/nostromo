//! Daemon-wide model state shared by every session: where the files are, the
//! catalogue, the channel model frames are broadcast on, and the last request
//! made for each focus.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, RwLock};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use tokio::sync::broadcast;
use tracing::{info, warn};

use super::catalog::{probe, ModelCatalog};
use super::{policy, store, Actor, ModelPaths, ModelTarget};
use crate::ipc::protocol::{LastModelRequest, ModelRequestStatus, ServerMsg};

/// The fewest seconds between two catalogue probes (one starts a CLI process,
/// and any client may ask for one).
pub const MIN_PROBE_INTERVAL: Duration = Duration::from_secs(30);

/// Probe bookkeeping: at most one in flight, and a minimum gap between starts.
struct ProbeGate {
    in_flight: bool,
    last_started: Option<Instant>,
    min_interval: Duration,
}

/// Held while a probe runs; frees the slot when dropped, however the probe ends.
struct ProbeSlot<'a>(&'a ModelHub);

impl Drop for ProbeSlot<'_> {
    fn drop(&mut self) {
        self.0.probe_gate.lock().unwrap_or_else(|e| e.into_inner()).in_flight = false;
    }
}

pub struct ModelHub {
    pub paths: ModelPaths,
    catalog: RwLock<ModelCatalog>,
    probe_gate: Mutex<ProbeGate>,
    broadcast: Mutex<Option<broadcast::Sender<ServerMsg>>>,
    last_requests: Mutex<HashMap<String, LastModelRequest>>,
    /// The `request_id` of the latest request per tag, stamped on every
    /// `last_request` recorded for it from then on.
    request_ids: Mutex<HashMap<String, Option<String>>>,
}

impl ModelHub {
    /// A hub over `paths`, starting from the cached catalogue. A cache is what
    /// an earlier run saw, so it is served `stale` until a probe succeeds.
    pub fn new(paths: ModelPaths) -> Self {
        let mut catalog = ModelCatalog::load(&paths.catalog);
        catalog.stale = !catalog.is_empty();
        Self {
            paths,
            catalog: RwLock::new(catalog),
            probe_gate: Mutex::new(ProbeGate {
                in_flight: false,
                last_started: None,
                min_interval: MIN_PROBE_INTERVAL,
            }),
            broadcast: Mutex::new(None),
            last_requests: Mutex::new(HashMap::new()),
            request_ids: Mutex::new(HashMap::new()),
        }
    }

    /// Change the minimum gap between probes (default [`MIN_PROBE_INTERVAL`]).
    pub fn set_min_probe_interval(&self, interval: Duration) {
        self.probe_gate.lock().unwrap_or_else(|e| e.into_inner()).min_interval = interval;
    }

    /// Claim the right to probe now: refused while another probe runs or the
    /// previous one started less than the minimum gap ago.
    fn begin_probe(&self) -> Result<ProbeSlot<'_>> {
        let mut gate = self.probe_gate.lock().unwrap_or_else(|e| e.into_inner());
        if gate.in_flight {
            return Err(anyhow!("a model catalogue probe is already running"));
        }
        let now = Instant::now();
        if let Some(last) = gate.last_started {
            if now.duration_since(last) < gate.min_interval {
                return Err(anyhow!("model catalogue probe throttled: probed a moment ago"));
            }
        }
        gate.in_flight = true;
        gate.last_started = Some(now);
        Ok(ProbeSlot(self))
    }

    /// Where model frames are broadcast (the daemon's client fan-out).
    pub fn set_broadcast(&self, tx: broadcast::Sender<ServerMsg>) {
        *self.broadcast.lock().unwrap() = Some(tx);
    }

    /// Send `msg` to every client (no-op until a channel is configured).
    pub fn broadcast(&self, msg: ServerMsg) {
        if let Some(tx) = self.broadcast.lock().unwrap().as_ref() {
            let _ = tx.send(msg);
        }
    }

    pub fn catalog(&self) -> ModelCatalog {
        self.catalog.read().unwrap().clone()
    }

    /// Install a freshly probed catalogue: cache it and tell every client.
    pub fn set_catalog(&self, catalog: ModelCatalog) {
        if let Err(e) = catalog.save(&self.paths.catalog) {
            warn!("could not cache the model catalogue: {e:#}");
        }
        *self.catalog.write().unwrap() = catalog;
        self.broadcast(self.catalog_msg());
    }

    /// The last probe failed: keep serving what we have, flagged stale.
    pub fn mark_stale(&self) {
        let changed = {
            let mut catalog = self.catalog.write().unwrap();
            let changed = !catalog.stale;
            catalog.stale = true;
            changed
        };
        if changed {
            self.broadcast(self.catalog_msg());
        }
    }

    pub fn catalog_msg(&self) -> ServerMsg {
        let catalog = self.catalog.read().unwrap();
        ServerMsg::ModelCatalog {
            families: catalog.families_wire(),
            stale: catalog.stale,
            fetched_at: catalog.fetched_at,
        }
    }

    /// The per-agent defaults and every agent's declared model.
    pub fn defaults_msg(&self) -> ServerMsg {
        ServerMsg::ModelDefaults {
            defaults: store::load_defaults(&self.paths.defaults),
            declared: policy::declared_models_in(&policy::agents_dir())
                .into_iter()
                .collect::<BTreeMap<_, _>>(),
        }
    }

    /// A new request for `tag` arrived, carrying `request_id` (if any).
    pub fn begin_request(&self, tag: &str, request_id: Option<String>) {
        self.request_ids.lock().unwrap().insert(tag.to_owned(), request_id);
    }

    /// Remember the latest request for `tag` (shown as `last_request`).
    pub fn record_request(
        &self,
        tag: &str,
        actor: &Actor,
        to: &ModelTarget,
        status: ModelRequestStatus,
    ) {
        let to = match &to.effort {
            Some(effort) => format!("{} · effort {effort}", to.model),
            None => to.model.clone(),
        };
        self.last_requests.lock().unwrap().insert(
            tag.to_owned(),
            LastModelRequest {
                actor: actor.wire(),
                to,
                status,
                ts: chrono::Utc::now(),
                request_id: self.request_ids.lock().unwrap().get(tag).cloned().flatten(),
            },
        );
    }

    pub fn last_request(&self, tag: &str) -> Option<LastModelRequest> {
        self.last_requests.lock().unwrap().get(tag).cloned()
    }

    /// Forget the request state of every tag that `is_live` rejects and whose
    /// last request is older than `cutoff` (a tag with a `request_id` but no
    /// recorded request goes with it). Returns how many tags were forgotten.
    pub fn forget_requests(
        &self,
        is_live: impl Fn(&str) -> bool,
        cutoff: chrono::DateTime<chrono::Utc>,
    ) -> usize {
        let mut last = self.last_requests.lock().unwrap();
        let mut ids = self.request_ids.lock().unwrap();
        let mut forgotten: std::collections::HashSet<String> = std::collections::HashSet::new();
        last.retain(|tag, request| {
            let keep = is_live(tag) || request.ts >= cutoff;
            if !keep {
                forgotten.insert(tag.clone());
            }
            keep
        });
        ids.retain(|tag, _| {
            let keep = is_live(tag) || last.contains_key(tag);
            if !keep {
                forgotten.insert(tag.clone());
            }
            keep
        });
        forgotten.len()
    }
}

/// Probe the installed CLI for its catalogue and install the result. On
/// failure (including an answer with no models) the cached catalogue is kept
/// and flagged stale. One probe at a time, and not within the hub's minimum
/// gap of the previous one: such a call does nothing and returns an error.
pub async fn refresh_catalog(hub: &ModelHub) -> Result<()> {
    let _slot = hub.begin_probe()?;
    let result = match crate::ipc::session_manager::resolve_claude() {
        Ok(claude) => probe(&claude).await,
        Err(e) => Err(e),
    };
    match result {
        Ok(catalog) => {
            info!(families = catalog.families.len(), "model catalogue probed");
            hub.set_catalog(catalog);
            Ok(())
        }
        Err(e) => {
            warn!("model catalogue probe failed; serving the cached one as stale: {e:#}");
            hub.mark_stale();
            Err(e)
        }
    }
}
