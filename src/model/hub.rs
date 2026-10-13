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

/// Held while a probe runs; frees the slot when dropped, however the probe
/// ends (an answer, a failure, or its future being cancelled). It owns what it
/// needs, so it can be handed to the thread the probe runs on.
struct ProbeSlot(Arc<Mutex<ProbeGate>>);

impl Drop for ProbeSlot {
    fn drop(&mut self) {
        lock(&self.0).in_flight = false;
    }
}

/// Lock `m`, taking the data even if a panicking holder poisoned it: the hub
/// is also touched from drop guards that run while a panic unwinds, where a
/// second panic would abort the daemon.
fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

pub struct ModelHub {
    pub paths: ModelPaths,
    catalog: RwLock<ModelCatalog>,
    /// A probe has SUCCEEDED since this hub was made (see [`Self::set_catalog`]).
    /// A failed probe does not count: until one succeeds the catalogue is
    /// only what an earlier run saw, and nothing in it may be passed to the
    /// CLI as a stored model.
    verified: AtomicBool,
    /// The first [`probe_before_use`] that had a probe to wait for has been
    /// made; later ones never wait.
    first_wait_taken: AtomicBool,
    probe_gate: Arc<Mutex<ProbeGate>>,
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
            verified: AtomicBool::new(false),
            first_wait_taken: AtomicBool::new(false),
            probe_gate: Arc::new(Mutex::new(ProbeGate {
                in_flight: false,
                last_started: None,
                min_interval: MIN_PROBE_INTERVAL,
            })),
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
        lock(&self.stored).insert(tag.to_owned(), (seq, target));
        seq
    }

    /// The switch `seq` of `tag` has been written (or failed to be). A later
    /// switch of the same tag stays.
    pub fn stored_done(&self, tag: &str, seq: u64) {
        let mut stored = lock(&self.stored);
        if stored.get(tag).is_some_and(|(latest, _)| *latest == seq) {
            stored.remove(tag);
        }
    }

    /// A guard for the job that writes switch `seq` of `tag` (see [`StoredGuard`]).
    pub fn guard_stored(self: &Arc<Self>, tag: &str, seq: u64, actor: Actor, target: ModelTarget) -> StoredGuard {
        StoredGuard { hub: Arc::clone(self), tag: tag.to_owned(), seq, actor, target }
    }

    /// What the latest switch of `tag` not yet written will make it run.
    pub fn stored_target(&self, tag: &str) -> Option<ModelTarget> {
        lock(&self.stored).get(tag).map(|(_, t)| t.clone())
    }

    /// Run `job` on the hub's IO thread: one thread, jobs in the order they
    /// were given, so two writes asked for one after the other land in that
    /// order. For work that must not run under the session manager's lock.
    /// A panicking job is dropped; the thread carries on.
    pub fn spawn_io(&self, job: IoJob) {
        let mut io = lock(&self.io);
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
        lock(&self.probe_gate).min_interval = interval;
    }

    /// Claim the right to probe now: refused while another probe runs or the
    /// previous one started less than the minimum gap ago.
    fn begin_probe(&self) -> Result<ProbeSlot> {
        let mut gate = lock(&self.probe_gate);
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
        Ok(ProbeSlot(Arc::clone(&self.probe_gate)))
    }

    fn probe_in_flight(&self) -> bool {
        lock(&self.probe_gate).in_flight
    }

    /// Where model frames are broadcast (the daemon's client fan-out).
    pub fn set_broadcast(&self, tx: broadcast::Sender<ServerMsg>) {
        *lock(&self.broadcast) = Some(tx);
    }

    /// Send `msg` to every client (no-op until a channel is configured).
    pub fn broadcast(&self, msg: ServerMsg) {
        if let Some(tx) = lock(&self.broadcast).as_ref() {
            let _ = tx.send(msg);
        }
    }

    pub fn catalog(&self) -> ModelCatalog {
        self.catalog.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Install a freshly probed catalogue: cache it and tell every client.
    pub fn set_catalog(&self, catalog: ModelCatalog) {
        if let Err(e) = catalog.save(&self.paths.catalog) {
            warn!("could not cache the model catalogue: {e:#}");
        }
        *self.catalog.write().unwrap_or_else(|e| e.into_inner()) = catalog;
        self.verified.store(true, Ordering::SeqCst);
        self.broadcast(self.catalog_msg());
    }

    /// Has a probe succeeded since this hub was made? Only then has the
    /// catalogue been checked against the installed CLI; a failed probe
    /// leaves this false, however many times it is tried.
    pub fn verified_this_run(&self) -> bool {
        self.verified.load(Ordering::SeqCst)
    }

    /// The last probe failed: keep serving what we have, flagged stale. Does
    /// not make the catalogue [verified](Self::verified_this_run).
    pub fn mark_stale(&self) {
        let changed = {
            let mut catalog = self.catalog.write().unwrap_or_else(|e| e.into_inner());
            let changed = !catalog.stale;
            catalog.stale = true;
            changed
        };
        if changed {
            self.broadcast(self.catalog_msg());
        }
    }

    pub fn catalog_msg(&self) -> ServerMsg {
        let catalog = self.catalog.read().unwrap_or_else(|e| e.into_inner());
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
        lock(&self.request_ids).insert(tag.to_owned(), request_id);
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
        lock(&self.last_requests).insert(
            tag.to_owned(),
            LastModelRequest {
                actor: actor.wire(),
                to,
                status,
                ts: chrono::Utc::now(),
                request_id: lock(&self.request_ids).get(tag).cloned().flatten(),
            },
        );
    }

    pub fn last_request(&self, tag: &str) -> Option<LastModelRequest> {
        lock(&self.last_requests).get(tag).cloned()
    }

    /// Forget the request state of every tag that `is_live` rejects and whose
    /// last request is older than `cutoff` (a tag with a `request_id` but no
    /// recorded request goes with it). Returns how many tags were forgotten.
    pub fn forget_requests(
        &self,
        is_live: impl Fn(&str) -> bool,
        cutoff: chrono::DateTime<chrono::Utc>,
    ) -> usize {
        let mut last = lock(&self.last_requests);
        let mut ids = lock(&self.request_ids);
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

/// Get a catalogue the installed CLI has vouched for before something relies
/// on it (one read from the cache at start has not been checked, and a model
/// it names may be gone). Does nothing once a probe has succeeded this run.
/// Otherwise it starts a probe on a thread of its own, runtime included (so it
/// works from inside or outside a runtime), unless one is already in flight
/// (the daemon's own) or the last started too recently (see
/// [`MIN_PROBE_INTERVAL`]).
///
/// Only the FIRST call that has a probe to wait for blocks, for at most
/// `limit`, and only while that probe runs: it returns as soon as the probe
/// has ended, well or badly, or has been cancelled. A later call, after a
/// failed first one, only retries in the background and returns at once, so a
/// CLI that can't be probed costs one wait, not one per start. The caller
/// asks [`ModelHub::verified_this_run`] for the outcome.
/// Blocks the caller: for use from synchronous code only.
pub fn probe_before_use(hub: &Arc<ModelHub>, limit: Duration) {
    if hub.verified_this_run() {
        return;
    }
    let may_wait = !hub.first_wait_taken.swap(true, Ordering::SeqCst);
    // The slot is taken here, not on the probe's thread, so that "no probe is
    // in flight" below can only mean the probe is over.
    let probing = match hub.begin_probe() {
        Ok(slot) => {
            let probe_hub = Arc::clone(hub);
            let started = std::thread::Builder::new().name("model-first-probe".into()).spawn(move || {
                match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                    Ok(runtime) => {
                        let _ = runtime.block_on(probe_and_install(&probe_hub, slot));
                    }
                    Err(e) => warn!("could not start a runtime for the model catalogue probe: {e}"),
                }
            });
            if let Err(e) = started {
                warn!("could not start the model catalogue probe: {e}");
            }
            true
        }
        // Already running (the daemon's own): worth waiting for. Throttled: not.
        Err(_) => hub.probe_in_flight(),
    };
    if !may_wait || !probing {
        return;
    }
    let deadline = Instant::now() + limit;
    while !hub.verified_this_run() && hub.probe_in_flight() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Probe the installed CLI for its catalogue and install the result. On
/// failure (including an answer with no models) the cached catalogue is kept
/// and flagged stale. One probe at a time, and not within the hub's minimum
/// gap of the previous one: such a call does nothing and returns an error.
pub async fn refresh_catalog(hub: &ModelHub) -> Result<()> {
    let slot = hub.begin_probe()?;
    probe_and_install(hub, slot).await
}

/// Run the probe `_slot` was taken for (and free the slot after, however it
/// ends, even if this future is dropped before it finishes).
async fn probe_and_install(hub: &ModelHub, _slot: ProbeSlot) -> Result<()> {
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

/// Held by the job that writes a stored switch of a stopped focus (see
/// [`ModelHub::note_stored`]). Dropping it, however the job ends, retires the
/// switch's "not yet written" entry: left behind by a job that panicked, the
/// entry would keep answering as the focus's model although it never landed.
/// A panic also records the request as failed.
pub struct StoredGuard {
    hub: Arc<ModelHub>,
    tag: String,
    seq: u64,
    actor: Actor,
    target: ModelTarget,
}

impl Drop for StoredGuard {
    fn drop(&mut self) {
        self.hub.stored_done(&self.tag, self.seq);
        if std::thread::panicking() {
            warn!(tag = %self.tag, "the job recording a model switch panicked: the switch was not recorded");
            self.hub.record_request(&self.tag, &self.actor, &self.target, ModelRequestStatus::Failed);
        }
    }
}
