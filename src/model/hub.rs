//! Daemon-wide model state shared by every session: where the files are, the
//! catalogue, the channel model frames are broadcast on, and the last request
//! made for each focus.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, RwLock};

use anyhow::Result;
use tokio::sync::broadcast;
use tracing::{info, warn};

use super::catalog::{probe, ModelCatalog};
use super::{policy, store, Actor, ModelPaths, ModelTarget};
use crate::ipc::protocol::{LastModelRequest, ModelRequestStatus, ServerMsg};

pub struct ModelHub {
    pub paths: ModelPaths,
    catalog: RwLock<ModelCatalog>,
    broadcast: Mutex<Option<broadcast::Sender<ServerMsg>>>,
    last_requests: Mutex<HashMap<String, LastModelRequest>>,
}

impl ModelHub {
    /// A hub over `paths`, starting from the cached catalogue.
    pub fn new(paths: ModelPaths) -> Self {
        let catalog = ModelCatalog::load(&paths.catalog);
        Self {
            paths,
            catalog: RwLock::new(catalog),
            broadcast: Mutex::new(None),
            last_requests: Mutex::new(HashMap::new()),
        }
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
            },
        );
    }

    pub fn last_request(&self, tag: &str) -> Option<LastModelRequest> {
        self.last_requests.lock().unwrap().get(tag).cloned()
    }
}

/// Probe the installed CLI for its catalogue and install the result. On
/// failure the cached catalogue is kept and flagged stale.
pub async fn refresh_catalog(hub: &ModelHub) -> Result<()> {
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
