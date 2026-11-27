//! Push notifications (W13): a closed-vocabulary push engine on the primary.
//!
//! The engine watches everything the primary sees (its own frames and every
//! satellite's), derives what is waiting on the operator ([`items`]), decides
//! when each device is told ([`schedule`], a pure state machine), renders the
//! text from a closed vocabulary ([`vocab`]) and hands it to a stateless relay
//! ([`publisher`]) that talks to Apple. Satellites send nothing to the relay.
//!
//! No text a worker, an agent, a person or GitHub wrote ever reaches a relay
//! request: see [`vocab`] and [`items`].

pub mod cli;
pub mod detail;
pub mod devices;
pub mod items;
pub mod owner;
pub mod publisher;
pub mod schedule;
pub mod sent_log;
pub mod vocab;
pub mod wire;

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use tokio::sync::{broadcast, mpsc};
use tracing::{debug, info, warn};

use crate::config::PushConfig;
use crate::data::perri_queue::PrQueueItem;
use crate::ipc::devices::{DeviceRegistry, DeviceStanding};
use crate::ipc::peer::{PeerTrust, SensitiveTags};
use crate::ipc::protocol::{ClientMsg, ServerMsg};
use crate::mother::MotherJob;
use detail::{Capture, ItemText};
use devices::{sanitize_prefs, valid_apns_token, DeviceStore, PushDevice};
use items::{
    decision_item, job_waits, mother_items, review_items, DecisionFacts, Detail, ItemKey, Waiting,
};
use publisher::{Delivery, InterruptionLevel, Publisher, PushType, RelayData, RelayRequest};
use schedule::{enabled_waiting, DeviceSchedule, Effect, ScheduleCfg};
use sent_log::{SentLine, SentLog};
use vocab::{render_alert, render_summary, render_withdrawal, RenderContext, Rendered};
use wire::{
    HostClass, PushCapabilities, PushEnvironment, PushKind, PushOutcome, PushPrefs, PushStatusBody,
    PushWaitingItem,
};

/// Advertised in `Welcome.features` by a primary that runs the engine.
pub const FEATURE_PUSH: &str = "push";
/// Advertised by a primary that runs the engine: it answers `PushDetail` (W16).
pub const FEATURE_PUSH_DETAIL: &str = "push_detail";
/// Advertised by every daemon: it accepts `operator_presence` from the verified app.
pub const FEATURE_PRESENCE: &str = "presence";

/// An item with no expiry of its own is held by Apple for at most this long.
const DEFAULT_EXPIRY: ChronoDuration = ChronoDuration::hours(4);
/// A satellite that is not connected and has said nothing for this long is
/// forgotten: its items are no longer counted.
const HOST_FORGET_AFTER: ChronoDuration = ChronoDuration::minutes(10);
/// How often the retained-frame cache is compared with what the engine holds.
const RECONCILE_EVERY: ChronoDuration = ChronoDuration::seconds(30);
/// A ceiling on open decisions tracked per host, whatever a satellite sends. It
/// is per host so one satellite cannot crowd out another's, or the daemon's own;
/// past it the host's oldest decision is dropped to make room.
const MAX_DECISIONS_PER_HOST: usize = 64;

/// Whether the push engine took a client message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dispatched {
    Handled,
    NotHandled,
}

/// Where the engine reads its `[push]` table, on every render, so that
/// `nostromo push host` takes effect without a restart.
pub type ConfigSource = Arc<dyn Fn() -> PushConfig + Send + Sync>;
/// The retained frames the server holds, for the periodic reconcile.
pub type RetainedSource = Arc<dyn Fn() -> Vec<ServerMsg> + Send + Sync>;

struct DecisionEntry {
    host: String,
    facts: DecisionFacts,
    raised: DateTime<Utc>,
}

struct State {
    devices: DeviceStore,
    sent: SentLog,
    schedules: BTreeMap<String, DeviceSchedule>,
    // What the sources last said, derived on arrival.
    mother: BTreeMap<String, Vec<Waiting>>,
    reviews: BTreeMap<String, Vec<Waiting>>,
    decisions: BTreeMap<(String, String), DecisionEntry>,
    // What an item's notification may say on the phone (W16), by item: captured
    // with the frame, pruned with the item, and judged again on every request.
    texts: BTreeMap<ItemKey, ItemText>,
    // Bookkeeping that follows an item's life.
    first_seen: BTreeMap<ItemKey, DateTime<Utc>>,
    refs: BTreeMap<ItemKey, String>,
    preexisting: BTreeSet<ItemKey>,
    review_host: BTreeMap<(String, u64), String>,
    // Satellites.
    host_seen: BTreeMap<String, DateTime<Utc>>,
    connected: BTreeSet<String>,
    seeded_mother: BTreeSet<String>,
    seeded_reviews: BTreeSet<String>,
    resync: bool,
    last_reconcile: DateTime<Utc>,
    last_prune: DateTime<Utc>,
}

/// One notification to send, with what to log about it.
struct Outgoing {
    push_id: String,
    request: RelayRequest,
    /// `(kind, host, title, body, outcome when Apple accepts)`; `None` for a
    /// badge-only push, which is not a notification and is not listed.
    log: Option<(String, String, String, String, PushOutcome)>,
}

pub struct PushEngine {
    config: ConfigSource,
    publisher: Publisher,
    registry: Option<Arc<DeviceRegistry>>,
    local_host: String,
    /// The daemon's sensitive-tag registry, for `PushDetail` (W16). Empty until set.
    sensitive: Mutex<SensitiveTags>,
    state: Mutex<State>,
    /// Serialises sends, so a notification and its replacement reach the relay
    /// in the order they were decided.
    gate: tokio::sync::Mutex<()>,
}

impl PushEngine {
    /// The engine, or `None` when `[push]` is absent, disabled, or names no relay.
    pub fn new(
        config: ConfigSource,
        local_host: String,
        registry: Option<Arc<DeviceRegistry>>,
    ) -> Option<Arc<Self>> {
        let cfg = config();
        let relay_url = cfg.relay_url.clone().filter(|u| !u.trim().is_empty())?;
        if !cfg.enabled {
            return None;
        }
        let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("."));
        let state_dir = cfg
            .state_dir
            .clone()
            .unwrap_or_else(|| home.join(".nostromo").join("push"));
        let token_path = cfg
            .relay_token_path
            .clone()
            .unwrap_or_else(|| home.join(".nostromo").join("push-relay-token"));
        let now = Utc::now();
        Some(Arc::new(Self {
            publisher: Publisher::new(&relay_url, token_path),
            config,
            registry,
            local_host,
            sensitive: Mutex::new(SensitiveTags::in_memory()),
            state: Mutex::new(State {
                devices: DeviceStore::load(state_dir.join("devices.json")),
                sent: SentLog::load(state_dir.join("sent.jsonl"), now),
                schedules: BTreeMap::new(),
                mother: BTreeMap::new(),
                reviews: BTreeMap::new(),
                decisions: BTreeMap::new(),
                texts: BTreeMap::new(),
                first_seen: BTreeMap::new(),
                refs: BTreeMap::new(),
                preexisting: BTreeSet::new(),
                review_host: BTreeMap::new(),
                host_seen: BTreeMap::new(),
                connected: BTreeSet::new(),
                seeded_mother: BTreeSet::new(),
                seeded_reviews: BTreeSet::new(),
                resync: false,
                last_reconcile: now,
                last_prune: now,
            }),
            gate: tokio::sync::Mutex::new(()),
        }))
    }

    /// Use the daemon's sensitive-tag registry when deciding whether an item's
    /// text may be shown on the phone (W16). Without it nothing is sensitive.
    pub fn set_sensitive_tags(&self, tags: SensitiveTags) {
        *self.sensitive.lock().unwrap() = tags;
    }

    /// Run the engine: watch the broadcast channel, and step every device's
    /// schedule on each relevant frame and once a second.
    pub fn spawn(
        self: &Arc<Self>,
        mut rx: broadcast::Receiver<ServerMsg>,
        retained: Option<RetainedSource>,
    ) -> tokio::task::JoinHandle<()> {
        let engine = Arc::clone(self);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(1));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            info!("push engine started");
            loop {
                let mut dirty = false;
                tokio::select! {
                    received = rx.recv() => match received {
                        Ok(msg) => dirty = engine.ingest(msg, Utc::now()),
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            warn!("push engine lagged {n} broadcast messages; it will reconcile");
                            engine.state.lock().unwrap().resync = true;
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    },
                    _ = tick.tick() => {
                        engine.housekeeping(retained.as_ref(), Utc::now());
                        dirty = true;
                    }
                }
                if dirty {
                    engine.run(Utc::now());
                }
            }
        })
    }

    // ── the paired phone's verbs ─────────────────────────────────────────────

    /// A paired phone's push verbs, scoped to its own device record. Handled only
    /// for `(Paired, Some(device_id))`; every other peer gets `NotHandled` and
    /// falls through to the refusal (the verbs are not network verbs).
    pub fn dispatch(
        &self,
        msg: &ClientMsg,
        trust: PeerTrust,
        ws_device: Option<&str>,
        reply: &mpsc::UnboundedSender<ServerMsg>,
    ) -> Dispatched {
        let (PeerTrust::Paired, Some(device_id)) = (trust, ws_device) else {
            return Dispatched::NotHandled;
        };
        let now = Utc::now();
        match msg {
            ClientMsg::RegisterPush {
                apns_token,
                environment,
                tz,
                capabilities,
            } => {
                self.register(device_id, apns_token, *environment, tz, *capabilities);
                let _ = reply.send(self.status_for(device_id));
            }
            ClientMsg::SetPushPrefs { prefs } => {
                self.set_prefs(device_id, prefs.clone());
                let _ = reply.send(self.status_for(device_id));
            }
            ClientMsg::PushSentLog => {
                let st = self.state.lock().unwrap();
                let entries = st
                    .devices
                    .get(device_id)
                    .map(|d| st.sent.entries_for(&d.push_id, now))
                    .unwrap_or_default();
                let _ = reply.send(ServerMsg::PushSentLog { entries });
            }
            ClientMsg::PushWaiting => {
                let _ = reply.send(self.waiting_for(device_id, now));
            }
            ClientMsg::PushDetail { item_ref } => {
                let _ = reply.send(self.detail_for(item_ref, now));
            }
            _ => return Dispatched::NotHandled,
        }
        Dispatched::Handled
    }

    fn register(
        &self,
        device_id: &str,
        apns_token: &str,
        environment: PushEnvironment,
        tz: &str,
        capabilities: PushCapabilities,
    ) {
        if !valid_apns_token(apns_token) {
            warn!("push registration refused: not an APNs token");
            return;
        }
        let mut st = self.state.lock().unwrap();
        if let Err(e) = st
            .devices
            .register(device_id, apns_token, environment, tz, capabilities)
        {
            warn!("push registration not saved: {e:#}");
        }
    }

    fn set_prefs(&self, device_id: &str, prefs: PushPrefs) {
        let Some(prefs) = sanitize_prefs(prefs) else {
            warn!("push settings refused: not valid");
            return;
        };
        let mut st = self.state.lock().unwrap();
        if let Err(e) = st.devices.set_prefs(device_id, prefs) {
            warn!("push settings not saved: {e:#}");
        }
    }

    fn status_for(&self, device_id: &str) -> ServerMsg {
        let cfg = (self.config)();
        let st = self.state.lock().unwrap();
        let (prefs, status) = match st.devices.get(device_id) {
            Some(d) => (d.prefs.clone(), st.sent.status(&d.push_id)),
            None => (PushPrefs::default(), Default::default()),
        };
        ServerMsg::PushStatus(PushStatusBody {
            prefs,
            host_classes: cfg.hosts.clone(),
            work_owners: cfg.resolved_work_owners(),
            last_ok_at: status.last_ok_at,
            failing_since: status.failing_since,
            review_queue_unfetched: self.hosts_without_a_review_queue(&st),
            registrations_refused: st.devices.unreadable_file().is_some(),
        })
    }

    /// The daemon's own host and every satellite heard from, minus those whose
    /// review queue has arrived at least once since start (a frame built
    /// before any fetch landed, `queue_unfetched`, does not count).
    fn hosts_without_a_review_queue(&self, st: &State) -> Vec<String> {
        let mut hosts: BTreeSet<&String> = st.host_seen.keys().collect();
        hosts.insert(&self.local_host);
        hosts
            .into_iter()
            .filter(|h| !st.seeded_reviews.contains(*h))
            .cloned()
            .collect()
    }

    fn waiting_for(&self, device_id: &str, now: DateTime<Utc>) -> ServerMsg {
        let mut st = self.state.lock().unwrap();
        let prefs = st
            .devices
            .get(device_id)
            .map(|d| d.prefs.clone())
            .unwrap_or_default();
        let waiting = self.waiting(&mut st, now);
        let enabled = enabled_waiting(&waiting, &prefs, now);
        let items = enabled
            .iter()
            .map(|w| PushWaitingItem {
                item_ref: w.item_ref.clone(),
                kind: w.kind(),
                host: vocab::host_label(&w.host).to_string(),
                ref_: match w.detail {
                    Detail::Decision { .. } => None,
                    _ => vocab::item_ref_text(w),
                },
            })
            .collect();
        ServerMsg::PushWaiting {
            items,
            badge: enabled.len() as u32,
        }
    }

    /// The answer to `PushDetail`: whether the item still waits and, only when
    /// [`detail::text_for`] allows it, its first line. The config is read before
    /// the state lock is taken.
    fn detail_for(&self, item_ref: &str, now: DateTime<Utc>) -> ServerMsg {
        let cfg = (self.config)();
        let sensitive = self.sensitive.lock().unwrap().clone();
        let mut st = self.state.lock().unwrap();
        let waiting = self.waiting(&mut st, now);
        match waiting.iter().find(|w| w.item_ref == item_ref) {
            Some(w) => ServerMsg::PushDetail {
                item_ref: w.item_ref.clone(),
                waiting: true,
                text: detail::text_for(w, st.texts.get(&w.key), &cfg, &sensitive),
                host: Some(vocab::host_label(&w.host).to_string()),
            },
            None => ServerMsg::PushDetail {
                item_ref: item_ref
                    .chars()
                    .take(detail::MAX_ITEM_REF_CHARS)
                    .collect::<String>(),
                waiting: false,
                text: None,
                host: None,
            },
        }
    }

    // ── sources ──────────────────────────────────────────────────────────────

    fn label(&self, host: Option<String>) -> String {
        host.unwrap_or_else(|| self.local_host.clone())
    }

    /// Fold one broadcast frame into the sources. True if the waiting set may
    /// have changed.
    pub fn ingest(&self, msg: ServerMsg, now: DateTime<Utc>) -> bool {
        if !matches!(
            msg,
            ServerMsg::MotherJobs { .. }
                | ServerMsg::PerriState { .. }
                | ServerMsg::DecisionRequest { .. }
                | ServerMsg::DecisionResolved { .. }
                | ServerMsg::Hosts { .. }
        ) {
            return false;
        }
        let mut st = self.state.lock().unwrap();
        match msg {
            ServerMsg::MotherJobs { jobs, host } => {
                let host = self.label(host);
                self.put_mother(&mut st, &host, mother_items(&host, &jobs), now);
                put_mother_texts(&mut st, &host, &jobs);
                true
            }
            // A frame built before any queue fetch landed says nothing: its empty
            // queue is unknown, not empty. Seeding from it would make every
            // requested review look new once the first real snapshot lands.
            ServerMsg::PerriState {
                queue_unfetched: true,
                ..
            } => false,
            ServerMsg::PerriState { queue, host, .. } => {
                let host = self.label(host);
                self.put_reviews(&mut st, &host, review_items(&host, &queue), now);
                put_review_texts(&mut st, &host, &queue);
                true
            }
            ServerMsg::DecisionRequest {
                tag,
                prompt,
                request_id,
                choices,
                host,
                deadline,
                agent_class,
                operator_presence,
                repo,
                repo_owner,
                ..
            } => {
                let host = self.label(host);
                let key = (host.clone(), request_id.clone());
                if !st.decisions.contains_key(&key) {
                    let mut mine: Vec<_> = st
                        .decisions
                        .iter()
                        .filter(|((h, _), _)| *h == host)
                        .map(|(k, d)| (d.raised, k.clone()))
                        .collect();
                    if mine.len() >= MAX_DECISIONS_PER_HOST {
                        mine.sort();
                        let evict = mine.len() + 1 - MAX_DECISIONS_PER_HOST;
                        for (_, k) in mine.into_iter().take(evict) {
                            st.decisions.remove(&k);
                            st.texts.remove(&ItemKey::Decision {
                                host: k.0,
                                request_id: k.1,
                            });
                        }
                    }
                }
                st.texts.insert(
                    ItemKey::Decision {
                        host: host.clone(),
                        request_id: request_id.clone(),
                    },
                    Capture::decision(&tag, repo.as_deref(), &prompt),
                );
                st.host_seen.insert(host.clone(), now);
                let raised = st.decisions.get(&key).map_or(now, |d| d.raised);
                st.decisions.insert(
                    key,
                    DecisionEntry {
                        host,
                        facts: DecisionFacts {
                            request_id,
                            choices: choices.len(),
                            deadline,
                            agent: agent_class,
                            presence: operator_presence,
                            repo,
                            owner: repo_owner,
                        },
                        raised,
                    },
                );
                true
            }
            ServerMsg::DecisionResolved {
                request_id, host, ..
            } => {
                let host = self.label(host);
                st.texts.remove(&ItemKey::Decision {
                    host: host.clone(),
                    request_id: request_id.clone(),
                });
                st.decisions.remove(&(host, request_id)).is_some()
            }
            ServerMsg::Hosts { hosts } => {
                st.connected = hosts.iter().map(|h| h.name.clone()).collect();
                for h in &hosts {
                    st.host_seen.insert(h.name.clone(), now);
                }
                false
            }
            _ => false,
        }
    }

    fn put_mother(&self, st: &mut State, host: &str, items: Vec<Waiting>, now: DateTime<Utc>) {
        st.host_seen.insert(host.to_string(), now);
        // The first snapshot of a host is what was already waiting.
        if st.seeded_mother.insert(host.to_string()) {
            st.preexisting.extend(items.iter().map(|w| w.key.clone()));
        }
        st.mother.insert(host.to_string(), items);
    }

    fn put_reviews(&self, st: &mut State, host: &str, items: Vec<Waiting>, now: DateTime<Utc>) {
        st.host_seen.insert(host.to_string(), now);
        if st.seeded_reviews.insert(host.to_string()) {
            st.preexisting.extend(items.iter().map(|w| w.key.clone()));
        }
        st.reviews.insert(host.to_string(), items);
    }

    /// Once a second: forget satellites that are gone, prune the sent log, and
    /// repair what a lagged receiver may have missed from the retained frames.
    pub fn housekeeping(&self, retained: Option<&RetainedSource>, now: DateTime<Utc>) {
        let snapshot = {
            let st = self.state.lock().unwrap();
            let due = st.resync || now - st.last_reconcile >= RECONCILE_EVERY;
            due.then(|| retained.map(|r| r())).flatten()
        };
        let mut st = self.state.lock().unwrap();
        if now - st.last_reconcile >= RECONCILE_EVERY || st.resync {
            let overwrite = std::mem::take(&mut st.resync);
            st.last_reconcile = now;
            for frame in snapshot.into_iter().flatten() {
                match frame {
                    ServerMsg::MotherJobs {
                        jobs,
                        host: Some(host),
                    } if overwrite || !st.mother.contains_key(&host) => {
                        self.put_mother(&mut st, &host, mother_items(&host, &jobs), now);
                        put_mother_texts(&mut st, &host, &jobs);
                    }
                    ServerMsg::PerriState {
                        queue,
                        host: Some(host),
                        queue_unfetched: false,
                        ..
                    } if overwrite || !st.reviews.contains_key(&host) => {
                        self.put_reviews(&mut st, &host, review_items(&host, &queue), now);
                        put_review_texts(&mut st, &host, &queue);
                    }
                    _ => {}
                }
            }
        }
        // A satellite that is not connected and has been silent is forgotten.
        let gone: Vec<String> = st
            .host_seen
            .iter()
            .filter(|(h, seen)| {
                **h != self.local_host
                    && !st.connected.contains(*h)
                    && now - **seen > HOST_FORGET_AFTER
            })
            .map(|(h, _)| h.clone())
            .collect();
        for host in gone {
            st.host_seen.remove(&host);
            st.mother.remove(&host);
            st.reviews.remove(&host);
            st.decisions.retain(|(h, _), _| *h != host);
            st.seeded_mother.remove(&host);
            st.seeded_reviews.remove(&host);
        }
        // A decision past its deadline is no longer waiting (its asker gave up).
        st.decisions
            .retain(|_, d| d.facts.deadline.is_none_or(|deadline| deadline > now));
        if now - st.last_prune >= ChronoDuration::hours(1) {
            st.last_prune = now;
            st.sent.prune(now);
        }
    }

    /// Everything waiting, across hosts, with each item's start and `item_ref`
    /// filled in. A PR seen on two hosts is one item, on the first host that
    /// reported it (and that keeps it for as long as it does).
    fn waiting(&self, st: &mut State, now: DateTime<Utc>) -> Vec<Waiting> {
        let mut out: Vec<Waiting> = st.mother.values().flatten().cloned().collect();

        let mut by_pr: BTreeMap<(String, u64), Vec<&Waiting>> = BTreeMap::new();
        for w in st.reviews.values().flatten() {
            if let ItemKey::Review { repo, number, .. } = &w.key {
                by_pr.entry((repo.clone(), *number)).or_default().push(w);
            }
        }
        let mut chosen = BTreeMap::new();
        for (pr, candidates) in &by_pr {
            let sticky = st
                .review_host
                .get(pr)
                .and_then(|h| candidates.iter().find(|w| w.host == *h));
            let local = candidates.iter().find(|w| w.host == self.local_host);
            let pick = sticky.or(local).or(candidates.first()).copied();
            if let Some(w) = pick {
                chosen.insert(pr.clone(), w.host.clone());
                out.push(w.clone());
            }
        }
        st.review_host = chosen;

        for d in st.decisions.values() {
            out.push(decision_item(&d.host, &d.facts, d.raised));
        }

        let present: BTreeSet<ItemKey> = out.iter().map(|w| w.key.clone()).collect();
        for w in &mut out {
            let first = *st.first_seen.entry(w.key.clone()).or_insert(now);
            w.start = Some(w.start.unwrap_or(first));
            w.item_ref = st
                .refs
                .entry(w.key.clone())
                .or_insert_with(new_item_ref)
                .clone();
            w.preexisting = st.preexisting.contains(&w.key);
        }
        st.texts.retain(|k, _| present.contains(k));
        st.first_seen.retain(|k, _| present.contains(k));
        st.refs.retain(|k, _| present.contains(k));
        st.preexisting.retain(|k| present.contains(k));
        out
    }

    // ── deciding and sending ─────────────────────────────────────────────────

    /// Step every device's schedule at `now` and send what is due, awaiting
    /// each send. [`PushEngine::spawn`] drives the engine from the clock; this
    /// is public so a test can drive it on a fabricated one.
    pub async fn step_at(&self, now: DateTime<Utc>) {
        // The config is read before the state lock is taken: it may read a file.
        let cfg = (self.config)();
        let sends = {
            let mut st = self.state.lock().unwrap();
            self.plan(&mut st, now, &cfg)
        };
        self.deliver(sends, now).await;
    }

    /// Step every device's schedule and send what is due, without waiting.
    fn run(self: &Arc<Self>, now: DateTime<Utc>) {
        let cfg = (self.config)();
        let sends = {
            let mut st = self.state.lock().unwrap();
            self.plan(&mut st, now, &cfg)
        };
        if sends.is_empty() {
            return;
        }
        let engine = Arc::clone(self);
        tokio::spawn(async move { engine.deliver(sends, now).await });
    }

    fn plan(&self, st: &mut State, now: DateTime<Utc>, cfg: &PushConfig) -> Vec<Outgoing> {
        // `enabled = false` in the config file takes effect at once. Schedules are
        // dropped, so turning it back on baselines what is waiting then instead of
        // pushing everything that arrived meanwhile.
        if !cfg.enabled {
            st.schedules.clear();
            return Vec::new();
        }
        let schedule_cfg = ScheduleCfg {
            grace: ChronoDuration::seconds(cfg.grace_secs.unwrap_or(120) as i64),
            decision_grace: ChronoDuration::seconds(cfg.decision_grace_secs.unwrap_or(30) as i64),
        };
        let work_owners = cfg.resolved_work_owners();

        // A revoked or unknown device is dropped, and its record deleted.
        if let Some(registry) = &self.registry {
            for id in st.devices.ids() {
                if registry.standing(&id) != Some(DeviceStanding::Active) {
                    if let Ok(Some(gone)) = st.devices.remove(&id) {
                        st.sent.forget(&gone.push_id);
                        debug!(device = %id, "push record dropped: device is not active");
                    }
                    st.schedules.remove(&id);
                }
            }
        }

        let waiting = self.waiting(st, now);
        let mut reviews_waiting: BTreeMap<String, usize> = BTreeMap::new();
        for w in &waiting {
            if matches!(w.detail, Detail::Review { .. }) {
                *reviews_waiting.entry(w.host.clone()).or_default() += 1;
            }
        }
        let ctx = RenderContext {
            hosts: &cfg.hosts,
            work_owners: &work_owners,
            reviews_waiting: &reviews_waiting,
            now,
        };

        let mut out = Vec::new();
        for id in st.devices.ids() {
            let Some(device) = st.devices.get(&id).cloned() else {
                continue;
            };
            // A device whose token Apple refused as dead waits for a fresh one. Its
            // schedule goes, so registering again baselines what is waiting then.
            if device.apns_token.is_empty() {
                st.schedules.remove(&id);
                continue;
            }
            let fresh = !st.schedules.contains_key(&id);
            let effects = st.schedules.entry(id.clone()).or_default().step(
                now,
                &waiting,
                &device.prefs,
                &schedule_cfg,
                fresh,
            );
            if effects.is_empty() {
                continue;
            }
            let enabled = enabled_waiting(&waiting, &device.prefs, now);
            let badge = enabled.len() as u32;
            for effect in effects {
                match effect {
                    Effect::Alert(w) => {
                        if let Some(r) = render_alert(&w, &ctx) {
                            out.push(alert(&device, &w, r, badge, now));
                        }
                    }
                    Effect::Summary { covered, .. } => {
                        for c in &covered {
                            if let Some(r) = render_alert(c, &ctx) {
                                log_line(st, &device, c, r, PushOutcome::Coalesced, now);
                            }
                        }
                        let oldest = enabled.iter().filter_map(|w| w.start).min();
                        let r = render_summary(&enabled, oldest, now);
                        out.push(summary(&device, r, badge, now));
                    }
                    Effect::Withdraw {
                        item,
                        had_notification,
                    } => {
                        let replacement = had_notification
                            .then(|| render_withdrawal(&item, &ctx))
                            .flatten();
                        out.push(match replacement {
                            Some(r) => withdrawal(&device, &item, r, badge, now),
                            None => badge_only(&device, &item, badge, now),
                        });
                    }
                    Effect::Log { item, outcome } => {
                        if let Some(r) = render_alert(&item, &ctx) {
                            log_line(st, &device, &item, r, outcome, now);
                        }
                    }
                }
            }
        }
        out
    }

    /// Send, in order, one at a time, and log what came of each at `now`. No retry.
    async fn deliver(&self, sends: Vec<Outgoing>, now: DateTime<Utc>) {
        let _gate = self.gate.lock().await;
        for send in sends {
            let delivery = self.publisher.send(&send.request).await;
            let mut st = self.state.lock().unwrap();
            if let Delivery::Rejected { status, reason } = &delivery {
                if token_is_dead(*status, reason.as_deref()) {
                    match st
                        .devices
                        .forget_dead_token(&send.push_id, &send.request.apns_token)
                    {
                        Ok(Some(id)) => {
                            warn!(device = %id, "apns refused a token as dead; waiting for a new one");
                            st.schedules.remove(&id);
                        }
                        Ok(None) => {}
                        Err(e) => warn!("dead token not cleared: {e:#}"),
                    }
                }
            }
            let outcome = |ok: PushOutcome| match &delivery {
                Delivery::Delivered => ok,
                Delivery::Rejected { .. } => PushOutcome::RejectedByApple,
                Delivery::Unreachable => PushOutcome::RelayUnreachable,
            };
            match send.log {
                Some((kind, host, title, body, ok)) => st.sent.append(
                    SentLine {
                        ts: now,
                        push_id: send.push_id,
                        kind,
                        host,
                        title,
                        body,
                        outcome: outcome(ok),
                    },
                    now,
                ),
                None => {
                    st.sent
                        .note_status(&send.push_id, outcome(PushOutcome::DeliveredToApple), now)
                }
            }
        }
    }
}

/// Whether Apple's answer means the token will never work again: `410` (the app
/// was uninstalled, `Unregistered`) or `400 BadDeviceToken`. Anything else
/// (payload, topic, throttling) is not the token's fault.
fn token_is_dead(status: u16, reason: Option<&str>) -> bool {
    status == 410 || (status == 400 && reason == Some("BadDeviceToken"))
}

/// Replace the texts kept for `host`'s Mother jobs with those of the jobs that wait.
fn put_mother_texts(st: &mut State, host: &str, jobs: &[MotherJob]) {
    st.texts
        .retain(|k, _| !matches!(k, ItemKey::Mother { host: h, .. } if h == host));
    for job in jobs.iter().filter(|j| job_waits(j)) {
        st.texts.insert(
            ItemKey::Mother {
                host: host.to_string(),
                job_id: job.id.clone(),
            },
            Capture::mother(job),
        );
    }
}

/// Replace the texts kept for `host`'s requested reviews.
fn put_review_texts(st: &mut State, host: &str, queue: &[PrQueueItem]) {
    st.texts
        .retain(|k, _| !matches!(k, ItemKey::Review { host: h, .. } if h == host));
    for pr in queue.iter().filter(|pr| pr.bucket == "requested") {
        st.texts.insert(
            ItemKey::Review {
                host: host.to_string(),
                repo: pr.repo.clone(),
                number: pr.number,
            },
            Capture::review(pr),
        );
    }
}

// ── building a request ───────────────────────────────────────────────────────

fn new_item_ref() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 8];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn kind_word(kind: PushKind) -> &'static str {
    kind.as_str()
}

#[allow(clippy::too_many_arguments)]
fn request(
    device: &PushDevice,
    collapse_id: &str,
    thread_id: &str,
    level: InterruptionLevel,
    priority: u8,
    expiration: DateTime<Utc>,
    text: Option<&Rendered>,
    badge: u32,
    data: RelayData,
) -> RelayRequest {
    RelayRequest {
        push_id: device.push_id.clone(),
        apns_token: device.apns_token.clone(),
        environment: device.environment,
        push_type: PushType::Alert,
        priority,
        expiration_unix: expiration.timestamp(),
        collapse_id: collapse_id.to_string(),
        thread_id: thread_id.to_string(),
        interruption_level: level,
        title: text.map(|t| t.title.clone()),
        body: text.map(|t| t.body.clone()),
        badge,
        // The extension runs only for a push that says so (W16).
        mutable_content: device.capabilities.nse,
        data,
    }
}

fn data_for(w: &Waiting, resolved: bool) -> RelayData {
    RelayData {
        item: w.item_ref.clone(),
        kind: kind_word(w.kind()).to_string(),
        host: vocab::host_label(&w.host).to_string(),
        ref_: match w.detail {
            Detail::Decision { .. } => None,
            _ => vocab::item_ref_text(w),
        },
        resolved: resolved.then_some(true),
    }
}

fn alert(
    device: &PushDevice,
    w: &Waiting,
    text: Rendered,
    badge: u32,
    now: DateTime<Utc>,
) -> Outgoing {
    let (level, expiry) = match &w.detail {
        Detail::Decision { deadline, .. } => (
            InterruptionLevel::TimeSensitive,
            deadline.unwrap_or(now + DEFAULT_EXPIRY),
        ),
        _ => (InterruptionLevel::Active, now + DEFAULT_EXPIRY),
    };
    Outgoing {
        push_id: device.push_id.clone(),
        request: request(
            device,
            &w.item_ref,
            vocab::host_label(&w.host),
            level,
            10,
            expiry,
            Some(&text),
            badge,
            data_for(w, false),
        ),
        log: Some((
            kind_word(w.kind()).to_string(),
            vocab::host_label(&w.host).to_string(),
            text.title,
            text.body,
            PushOutcome::DeliveredToApple,
        )),
    }
}

fn summary(device: &PushDevice, text: Rendered, badge: u32, now: DateTime<Utc>) -> Outgoing {
    Outgoing {
        push_id: device.push_id.clone(),
        request: request(
            device,
            "summary",
            "summary",
            InterruptionLevel::Active,
            10,
            now + DEFAULT_EXPIRY,
            Some(&text),
            badge,
            RelayData {
                item: "summary".to_string(),
                kind: "summary".to_string(),
                host: "all".to_string(),
                ref_: None,
                resolved: None,
            },
        ),
        log: Some((
            "summary".to_string(),
            "all".to_string(),
            text.title,
            text.body,
            PushOutcome::DeliveredToApple,
        )),
    }
}

/// The passive replacement of a delivered notification, in place (same collapse id).
fn withdrawal(
    device: &PushDevice,
    w: &Waiting,
    text: Rendered,
    badge: u32,
    now: DateTime<Utc>,
) -> Outgoing {
    Outgoing {
        push_id: device.push_id.clone(),
        request: request(
            device,
            &w.item_ref,
            vocab::host_label(&w.host),
            InterruptionLevel::Passive,
            10,
            now + DEFAULT_EXPIRY,
            Some(&text),
            badge,
            data_for(w, true),
        ),
        log: Some((
            kind_word(w.kind()).to_string(),
            vocab::host_label(&w.host).to_string(),
            text.title,
            text.body,
            PushOutcome::Withdrawn,
        )),
    }
}

/// A push that only corrects the badge: no title, no body, no sound.
fn badge_only(device: &PushDevice, w: &Waiting, badge: u32, now: DateTime<Utc>) -> Outgoing {
    Outgoing {
        push_id: device.push_id.clone(),
        request: request(
            device,
            &w.item_ref,
            vocab::host_label(&w.host),
            InterruptionLevel::Passive,
            5,
            now + DEFAULT_EXPIRY,
            None,
            badge,
            data_for(w, true),
        ),
        log: None,
    }
}

/// A line for something that is logged but not sent.
fn log_line(
    st: &mut State,
    device: &PushDevice,
    w: &Waiting,
    text: Rendered,
    outcome: PushOutcome,
    now: DateTime<Utc>,
) {
    st.sent.append(
        SentLine {
            ts: now,
            push_id: device.push_id.clone(),
            kind: kind_word(w.kind()).to_string(),
            host: vocab::host_label(&w.host).to_string(),
            title: text.title,
            body: text.body,
            outcome,
        },
        now,
    );
}

/// A [`ConfigSource`] that re-reads `[push]` from the config file (at most every
/// two seconds), so `nostromo push host` takes effect without a restart. A file
/// that cannot be read keeps the last good table.
pub fn config_from_file(startup: PushConfig) -> ConfigSource {
    config_reloading(startup, Duration::from_secs(2), || {
        Ok(crate::config::Config::load(None)?.push)
    })
}

/// [`config_from_file`] over any loader, so the reload rules can be tested: the
/// table is re-read at most every `every`; a loader error (a file that does not
/// parse) is logged at warn and the last good table is kept; an absent table
/// keeps the last good one too.
fn config_reloading(
    startup: PushConfig,
    every: Duration,
    load: impl Fn() -> anyhow::Result<Option<PushConfig>> + Send + Sync + 'static,
) -> ConfigSource {
    let memo = Mutex::new((std::time::Instant::now(), startup));
    Arc::new(move || {
        let mut memo = memo.lock().unwrap();
        if memo.0.elapsed() >= every {
            match load() {
                Ok(Some(push)) => memo.1 = push,
                Ok(None) => {}
                Err(e) => warn!("push config not reloaded, keeping the last good one: {e:#}"),
            }
            memo.0 = std::time::Instant::now();
        }
        memo.1.clone()
    })
}

/// The host label of the daemon's own frames: `host_name`, else the OS host
/// name's first label, lower-cased; `local` if neither is usable.
pub fn local_host_label(configured: Option<&str>) -> String {
    let name = configured.map(str::to_string).or_else(|| {
        hostname::get()
            .ok()
            .and_then(|h| h.into_string().ok())
            .and_then(|h| h.split('.').next().map(str::to_ascii_lowercase))
    });
    name.filter(|n| crate::config::valid_host_name(n))
        .unwrap_or_else(|| "local".to_string())
}

/// What the host classification says about `host` (absent = work).
pub fn host_class(cfg: &PushConfig, host: &str) -> HostClass {
    cfg.hosts.get(host).copied().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::OnceLock;

    fn pc(url: &str, dir: &Path) -> PushConfig {
        PushConfig {
            relay_url: Some(url.to_string()),
            relay_token_path: Some(dir.join("token")),
            state_dir: Some(dir.join("push")),
            ..Default::default()
        }
    }

    fn decision_frame(request_id: &str) -> ServerMsg {
        ServerMsg::DecisionRequest {
            tag: "t".into(),
            request_id: request_id.into(),
            prompt: "Which one?".into(),
            detail: None,
            choices: vec![],
            context_pane_id: None,
            host: None,
            deadline: None,
            agent_class: None,
            operator_presence: None,
            repo: None,
            repo_owner: None,
        }
    }

    /// The text kept for a decision goes with the decision: not only at the next plan, but at once,
    /// so a flood of requests cannot grow the text map between plans.
    #[test]
    fn a_flood_of_decisions_never_holds_more_texts_than_the_per_host_cap() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = pc("http://127.0.0.1:9", dir.path());
        let engine =
            PushEngine::new(Arc::new(move || cfg.clone()), "local".into(), None).expect("engine");
        for i in 0..MAX_DECISIONS_PER_HOST * 3 {
            engine.ingest(decision_frame(&format!("r{i}")), Utc::now());
        }
        let st = engine.state.lock().unwrap();
        assert_eq!(st.decisions.len(), MAX_DECISIONS_PER_HOST);
        assert_eq!(st.texts.len(), MAX_DECISIONS_PER_HOST);
    }

    #[test]
    fn a_resolved_decision_loses_its_text_at_once() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = pc("http://127.0.0.1:9", dir.path());
        let engine =
            PushEngine::new(Arc::new(move || cfg.clone()), "local".into(), None).expect("engine");
        engine.ingest(decision_frame("r1"), Utc::now());
        assert_eq!(engine.state.lock().unwrap().texts.len(), 1);
        engine.ingest(
            ServerMsg::DecisionResolved {
                tag: "t".into(),
                request_id: "r1".into(),
                resolution: crate::ipc::protocol::DecisionResolution::Answered,
                choice_id: None,
                host: None,
            },
            Utc::now(),
        );
        assert!(engine.state.lock().unwrap().texts.is_empty());
    }

    #[tokio::test]
    async fn the_config_is_never_read_while_the_state_lock_is_held() {
        let dir = tempfile::tempdir().unwrap();
        let base = pc("http://127.0.0.1:9", dir.path());
        let engine_cell: Arc<OnceLock<std::sync::Weak<PushEngine>>> = Arc::new(OnceLock::new());
        let held = Arc::new(AtomicBool::new(false));
        let reads = Arc::new(AtomicUsize::new(0));
        let source: ConfigSource = {
            let (cell, held, reads) = (
                Arc::clone(&engine_cell),
                Arc::clone(&held),
                Arc::clone(&reads),
            );
            Arc::new(move || {
                if let Some(engine) = cell.get().and_then(std::sync::Weak::upgrade) {
                    reads.fetch_add(1, Ordering::SeqCst);
                    // A lock that cannot be taken here is held by the caller.
                    if engine.state.try_lock().is_err() {
                        held.store(true, Ordering::SeqCst);
                    }
                }
                base.clone()
            })
        };
        let engine = PushEngine::new(source, "local".into(), None).expect("an enabled engine");
        engine_cell.set(Arc::downgrade(&engine)).unwrap();

        engine.step_at(Utc::now()).await;
        engine.run(Utc::now());

        assert!(reads.load(Ordering::SeqCst) >= 2, "the config was read");
        assert!(
            !held.load(Ordering::SeqCst),
            "the config source ran with the engine's state lock held"
        );
    }

    #[test]
    fn a_config_that_stops_parsing_keeps_the_last_good_table_and_a_fixed_one_is_picked_up() {
        let dir = tempfile::tempdir().unwrap();
        let startup = pc("http://relay.example", dir.path());
        let answers: Arc<Mutex<Vec<anyhow::Result<Option<PushConfig>>>>> =
            Arc::new(Mutex::new(vec![
                Err(anyhow::anyhow!("expected `=` at line 3")),
                Ok(None),
                Ok(Some(PushConfig {
                    grace_secs: Some(7),
                    ..startup.clone()
                })),
            ]));
        let source = {
            let answers = Arc::clone(&answers);
            config_reloading(startup.clone(), Duration::ZERO, move || {
                answers.lock().unwrap().remove(0)
            })
        };
        assert_eq!(
            source().grace_secs,
            None,
            "a parse error keeps the last good table"
        );
        assert_eq!(source().grace_secs, None, "an absent table keeps it too");
        assert_eq!(
            source().grace_secs,
            Some(7),
            "a fixed file is picked up without a restart"
        );
    }

    #[test]
    fn the_table_is_re_read_at_most_once_per_interval() {
        let dir = tempfile::tempdir().unwrap();
        let loads = Arc::new(AtomicUsize::new(0));
        let source = {
            let loads = Arc::clone(&loads);
            config_reloading(
                pc("http://relay.example", dir.path()),
                Duration::from_secs(3600),
                move || {
                    loads.fetch_add(1, Ordering::SeqCst);
                    Ok(None)
                },
            )
        };
        for _ in 0..5 {
            source();
        }
        assert_eq!(
            loads.load(Ordering::SeqCst),
            0,
            "inside the interval nothing is re-read"
        );
    }
}
