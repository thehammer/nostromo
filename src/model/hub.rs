//! Daemon-wide model state shared by every session: where the files are, the
//! catalogue, the channel model frames are broadcast on, and the last request
//! made for each focus.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, RwLock};
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
    /// A probe has finished since this hub was made (it installed a
    /// catalogue, or failed and flagged the cached one stale). Until then
    /// the catalogue is only what an earlier run saw.
    probed: AtomicBool,
    probe_gate: Mutex<ProbeGate>,
    broadcast: Mutex<Option<broadcast::Sender<ServerMsg>>>,
    last_requests: Mutex<HashMap<String, LastModelRequest>>,
    /// The `request_id` of the latest request per tag, stamped on every
    /// `last_request` recorded for it from then on.
    request_ids: Mutex<HashMap<String, Option<String>>>,
    /// Switches of stopped focuses asked for but not yet written (see
    /// [`Self::note_stored`]), by tag: the sequence number of the latest, and
    /// its target.
    stored: Mutex<HashMap<String, (u64, ModelTarget)>>,
    stored_seq: AtomicU64,
    /// Feeds the thread that runs [`Self::spawn_io`] jobs, started on first use.
    io: Mutex<Option<mpsc::Sender<IoJob>>>,
}

/// A piece of slow work (disk writes) for the hub's IO thread.
pub type IoJob = Box<dyn FnOnce() + Send + 'static>;

impl ModelHub {
    /// A hub over `paths`, starting from the cached catalogue. A cache is what
    /// an earlier run saw, so it is served `stale` until a probe succeeds.
    pub fn new(paths: ModelPaths) -> Self {
        // Leftovers of writes an earlier run died in the middle of.
        let mut dirs: Vec<&Path> = [&paths.focus_models, &paths.defaults, &paths.catalog]
            .into_iter()
            .filter_map(|p| p.parent())
            .collect();
        dirs.dedup();
        for dir in dirs {
            let removed = store::sweep_temp_files(dir);
            if removed > 0 {
                info!(removed, dir = %dir.display(), "removed temp files left by an interrupted model store write");
            }
        }
        let mut catalog = ModelCatalog::load(&paths.catalog);
        catalog.stale = !catalog.is_empty();
        Self {
            paths,
            catalog: RwLock::new(catalog),
            probed: AtomicBool::new(false),
            probe_gate: Mutex::new(ProbeGate {
                in_flight: false,
                last_started: None,
                min_interval: MIN_PROBE_INTERVAL,
            }),
            broadcast: Mutex::new(None),
            last_requests: Mutex::new(HashMap::new()),
            request_ids: Mutex::new(HashMap::new()),
            stored: Mutex::new(HashMap::new()),
            stored_seq: AtomicU64::new(0),
            io: Mutex::new(None),
        }
    }

    /// A switch of the stopped focus `tag` to `target` was asked for and will
    /// be written on the IO thread. Until [`Self::stored_done`] says so, it is
    /// what the focus runs as far as the next request is concerned, which
    /// would otherwise read the older record still on disk. Returns the
    /// switch's sequence number.
    pub fn note_stored(&self, tag: &str, target: ModelTarget) -> u64 {
        let seq = self.stored_seq.fetch_add(1, Ordering::SeqCst) + 1;
        self.stored.lock().unwrap_or_else(|e| e.into_inner()).insert(tag.to_owned(), (seq, target));
        seq
    }

    /// The switch `seq` of `tag` has been written (or failed to be). A later
    /// switch of the same tag stays.
    pub fn stored_done(&self, tag: &str, seq: u64) {
        let mut stored = self.stored.lock().unwrap_or_else(|e| e.into_inner());
        if stored.get(tag).is_some_and(|(latest, _)| *latest == seq) {
            stored.remove(tag);
        }
    }

    /// What the latest switch of `tag` not yet written will make it run.
    pub fn stored_target(&self, tag: &str) -> Option<ModelTarget> {
        self.stored.lock().unwrap_or_else(|e| e.into_inner()).get(tag).map(|(_, t)| t.clone())
    }

    /// Run `job` on the hub's IO thread: one thread, jobs in the order they
    /// were given, so two writes asked for one after the other land in that
    /// order. For work that must not run under the session manager's lock.
    /// A panicking job is dropped; the thread carries on.
    pub fn spawn_io(&self, job: IoJob) {
        let mut io = self.io.lock().unwrap_or_else(|e| e.into_inner());
        let mut job = Some(job);
        // A second try covers an IO thread that is gone (it could not start).
        for _ in 0..2 {
            if io.is_none() {
                let (tx, rx) = mpsc::channel::<IoJob>();
                let started = std::thread::Builder::new().name("model-io".into()).spawn(move || {
                    for job in rx {
                        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(job));
                    }
                });
                match started {
                    Ok(_) => *io = Some(tx),
                    Err(e) => {
                        warn!("could not start the model IO thread: {e}");
                        break;
                    }
                }
            }
            let Some(tx) = io.as_ref() else { break };
            match tx.send(job.take().expect("job is set until it is sent")) {
                Ok(()) => return,
                Err(mpsc::SendError(back)) => {
                    job = Some(back);
                    *io = None;
                }
            }
        }
        // No thread to run it on: run it here rather than lose it.
        if let Some(job) = job {
            job();
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
        self.probed.store(true, Ordering::SeqCst);
        self.broadcast(self.catalog_msg());
    }

    /// Has a probe finished (well or badly) since this hub was made?
    pub fn probed_this_run(&self) -> bool {
        self.probed.load(Ordering::SeqCst)
    }

    /// The last probe failed: keep serving what we have, flagged stale.
    pub fn mark_stale(&self) {
        self.probed.store(true, Ordering::SeqCst);
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

/// How long [`probe_before_use`] waits: a probe's own limit, plus a little.
pub const FIRST_PROBE_WAIT: Duration =
    Duration::from_secs(super::catalog::PROBE_TIMEOUT.as_secs() + 2);

/// Make sure a probe has finished before something relies on the catalogue
/// (a catalogue read from the cache at start has not been checked against
/// the installed CLI). Does nothing once any probe has finished. Otherwise it
/// runs one on a thread of its own, runtime included (so it works from inside
/// or outside a runtime), and waits for the outcome for at most `limit`;
/// a probe already in flight (the daemon's own) is waited for instead.
/// Blocks the caller: for use from synchronous code only.
pub fn probe_before_use(hub: &Arc<ModelHub>, limit: Duration) {
    if hub.probed_this_run() {
        return;
    }
    let probe_hub = Arc::clone(hub);
    let started = std::thread::Builder::new().name("model-first-probe".into()).spawn(move || {
        match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(runtime) => {
                let _ = runtime.block_on(refresh_catalog(&probe_hub));
            }
            Err(e) => warn!("could not start a runtime for the model catalogue probe: {e}"),
        }
    });
    if let Err(e) = started {
        warn!("could not start the model catalogue probe: {e}");
    }
    let deadline = Instant::now() + limit;
    while !hub.probed_this_run() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
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
