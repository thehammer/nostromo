//! A satellite's uplink: the daemon dials its primary, publishes what its own
//! clients see (filtered by its egress profile and stamped with its host name),
//! answers the few reads the primary routes down, and carries its local
//! clients' device-administration verbs up the same socket.
//!
//! Everything here is outbound. Nothing listens, and nothing the primary sends
//! is acted on beyond: the six routable read verbs (a `personal` satellite
//! only), and the device-administration answers for the verbs this satellite
//! itself relayed. Every other frame from the primary is dropped (B10: no
//! approval, decision, Mother or session-driving verb is ever dispatched from
//! an uplink).
//!
//! What leaves is judged twice: by the [`Forwarder`] here, and again by the
//! primary's `router::ingest_from_satellite`. The forwarder runs the
//! primary's own check on every frame it is about to send, so it never sends
//! what the primary would drop, and a nothing-administrative frame is ever
//! echoed upward: it only forwards host-carrying state variants.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures::{SinkExt, StreamExt};
use rand::RngCore;
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use tracing::{debug, error, info, warn};

use crate::config::SatelliteSetup;
use crate::ipc::devices::{Egress, SatelliteAdmin};
use crate::ipc::peer::{
    outbound, redact_for_uplink_metadata, withheld_msg, PeerTrust, SensitiveTags,
};
use crate::ipc::protocol::{ClientMsg, HelloRole, ServerMsg, Topic, PROTOCOL_VERSION};
use crate::ipc::router::{ingest_from_satellite, server_msg_host, SatelliteRecord};
use crate::ipc::server::{message_matches_topics, LocalDispatch};
use crate::ipc::uplink_wire::UplinkFrame;

use super::ws::FEATURE_UPLINK;

/// First step of the reconnect backoff, and its cap.
const BACKOFF_START: Duration = Duration::from_secs(1);
const BACKOFF_CAP: Duration = Duration::from_secs(60);
/// How long a satellite waits before trying a primary that does not advertise
/// `"uplink"` again.
const NO_UPLINK_RETRY: Duration = Duration::from_secs(600);
/// How long the primary may take to answer the `Hello` with a `Welcome`.
const WELCOME_TIMEOUT: Duration = Duration::from_secs(15);
/// Spacing of published frames: 40 a second, under the primary's 50/s bucket.
const PUBLISH_SPACING: Duration = Duration::from_millis(25);
/// A single-answer routed read's local connection is dropped after this long.
const ROUTED_TTL: Duration = Duration::from_secs(10);
/// A pending `DeviceList` waits this long for its answer.
const LIST_TTL: Duration = Duration::from_secs(10);
/// Most frames kept to replay on reconnect.
const MAX_CACHED: usize = 512;

/// The refusal a verb gets when the effective level does not allow it, and
/// when the uplink is down.
pub const NOT_PERMITTED: &str = "not_permitted_on_this_mac";
pub const SERVER_UNREACHABLE: &str = "server_unreachable";

// ── the egress filter ─────────────────────────────────────────────────────────

/// Which focus tags belong to a PHI repo, learned from the focus frames that
/// pass through, plus the repo names themselves.
#[derive(Debug, Clone)]
pub struct PhiScope {
    repos: Vec<String>,
    tags: HashSet<String>,
}

impl PhiScope {
    pub fn new(repos: Vec<String>) -> Self {
        Self {
            repos,
            tags: HashSet::new(),
        }
    }

    fn path_is_phi(&self, path: &str) -> bool {
        let last = path
            .trim_end_matches(['/', '\\'])
            .rsplit(['/', '\\'])
            .next()
            .unwrap_or("");
        self.repos.iter().any(|r| r == last)
    }

    fn focus_is_phi(&self, meta: &crate::ipc::protocol::FocusMeta) -> bool {
        meta.project_path
            .as_deref()
            .is_some_and(|p| self.path_is_phi(p))
            || meta
                .project_name
                .as_deref()
                .is_some_and(|n| self.repos.iter().any(|r| r == n))
    }

    /// Learn which tags are PHI-scoped from a focus frame.
    pub fn observe(&mut self, msg: &ServerMsg) {
        match msg {
            ServerMsg::FocusListResp { focuses, .. }
            | ServerMsg::FocusRegistryUpdated { focuses, .. } => {
                let phi: HashSet<String> = focuses
                    .iter()
                    .filter(|f| self.focus_is_phi(f))
                    .map(|f| f.tag.clone())
                    .collect();
                self.tags = phi;
            }
            ServerMsg::FocusCreated { meta, .. } if self.focus_is_phi(meta) => {
                self.tags.insert(meta.tag.clone());
            }
            _ => {}
        }
    }

    /// Is a request or frame about a PHI focus?
    pub fn tag_is_phi(&self, tag: &str) -> bool {
        self.tags.contains(tag)
    }

    fn job_is_phi(&self, job: &crate::mother::MotherJob) -> bool {
        self.path_is_phi(&job.repo)
    }

    /// `msg` without its PHI-scoped content; `None` when nothing is left that
    /// is not about a PHI repo. A `personal` satellite's PHI work is never sent
    /// at all (the primary only accepts a `personal` frame the network filter
    /// leaves unchanged, so a metadata-only version could not be delivered).
    pub fn strip(&self, msg: ServerMsg) -> Option<ServerMsg> {
        match msg {
            ServerMsg::MotherJobs { jobs, host } => Some(ServerMsg::MotherJobs {
                jobs: jobs.into_iter().filter(|j| !self.job_is_phi(j)).collect(),
                host,
            }),
            ServerMsg::FocusListResp { focuses, host } => Some(ServerMsg::FocusListResp {
                focuses: focuses
                    .into_iter()
                    .filter(|f| !self.focus_is_phi(f))
                    .collect(),
                host,
            }),
            ServerMsg::FocusRegistryUpdated { focuses, host } => {
                Some(ServerMsg::FocusRegistryUpdated {
                    focuses: focuses
                        .into_iter()
                        .filter(|f| !self.focus_is_phi(f))
                        .collect(),
                    host,
                })
            }
            ServerMsg::FocusCreated { meta, host } => {
                (!self.focus_is_phi(&meta)).then_some(ServerMsg::FocusCreated { meta, host })
            }
            ServerMsg::SessionListResp { sessions, host } => Some(ServerMsg::SessionListResp {
                sessions: sessions
                    .into_iter()
                    .filter(|s| !self.tags.contains(&s.tag))
                    .collect(),
                host,
            }),
            other => match frame_tag(&other) {
                Some(tag) if self.tags.contains(&tag) => None,
                _ => Some(other),
            },
        }
    }
}

/// The focus tag a frame carries, if it has one.
fn frame_tag(msg: &ServerMsg) -> Option<String> {
    serde_json::to_value(msg)
        .ok()
        .and_then(|v| v.get("tag").and_then(|t| t.as_str().map(String::from)))
}

/// Set the `host` field of a host-carrying frame. `None` when the variant has
/// no such field.
fn stamp_host(msg: ServerMsg, host: &str) -> Option<ServerMsg> {
    server_msg_host(&msg)?;
    let mut v = serde_json::to_value(&msg).ok()?;
    v.as_object_mut()?
        .insert("host".to_string(), serde_json::json!(host));
    serde_json::from_value(v).ok()
}

/// What a frame is retained under for replay on reconnect: the state
/// variants only (a stream such as `Activity` is not state).
fn cache_key(msg: &ServerMsg) -> Option<String> {
    let v = serde_json::to_value(msg).ok()?;
    let ty = v.get("type")?.as_str()?;
    match ty {
        "mother_jobs" | "mother_statusline" | "focus_registry_updated" => Some(ty.to_string()),
        "perri_state" | "session_state" | "session_bridge" | "approval_pending"
        | "tracker_summary" => Some(format!(
            "{ty}:{}",
            v.get("tag").and_then(|t| t.as_str()).unwrap_or("")
        )),
        _ => None,
    }
}

/// Everything the uplink applies to a frame before it leaves this machine.
pub struct Forwarder {
    host: String,
    egress: Egress,
    host_key: [u8; 32],
    tags: SensitiveTags,
    phi: PhiScope,
    publish_topics: Option<Vec<Topic>>,
}

impl Forwarder {
    pub fn new(
        host: String,
        egress: Egress,
        host_key: [u8; 32],
        tags: SensitiveTags,
        phi_repos: Vec<String>,
        publish_topics: Option<Vec<Topic>>,
    ) -> Self {
        Self {
            host,
            egress,
            host_key,
            tags,
            phi: PhiScope::new(phi_repos),
            publish_topics,
        }
    }

    pub fn phi(&self) -> &PhiScope {
        &self.phi
    }

    /// The frame to publish for a broadcast, or `None` to keep it home.
    ///
    /// In order: (1) only the host-carrying state variants (never an
    /// administrative, local-only or bookkeeping frame, so nothing
    /// administrative is ever echoed upward), and only topics in
    /// `publish_topics`; (2) a `work` host's frame is reduced to metadata
    /// (sensitive focuses and jobs removed first), a `personal` host's frame
    /// is what a network peer would be sent, without its PHI-repo content;
    /// (3) the host is stamped; and last, the primary's own ingest check, so
    /// nothing is sent that the primary would drop.
    pub fn publish(&mut self, msg: ServerMsg) -> Option<ServerMsg> {
        self.phi.observe(&msg);
        server_msg_host(&msg)?;
        if let Some(topics) = &self.publish_topics {
            if !message_matches_topics(&msg, topics) {
                return None;
            }
        }
        let shaped = match self.egress {
            Egress::Work => redact_for_uplink_metadata(msg, &self.host_key, &self.tags)?,
            Egress::Personal => {
                let msg = self.phi.strip(msg)?;
                outbound(PeerTrust::Tcp, msg, &self.tags)?
            }
        };
        let stamped = stamp_host(shaped, &self.host)?;
        let record = SatelliteRecord {
            name: self.host.clone(),
            egress: self.egress,
        };
        ingest_from_satellite(&record, stamped, &self.tags).ok()
    }

    /// The frame to send as the answer to a routed read, or `None`. Only a
    /// `personal` host answers routed reads.
    pub fn reply(&self, msg: ServerMsg) -> Option<ServerMsg> {
        if self.egress != Egress::Personal {
            return None;
        }
        let msg = self.phi.strip(msg)?;
        let msg = outbound(PeerTrust::Routed, msg, &self.tags)?;
        let msg = if server_msg_host(&msg).is_some() {
            stamp_host(msg, &self.host)?
        } else {
            msg
        };
        // What the primary will accept: unchanged by the network filter.
        let after = outbound(PeerTrust::Tcp, msg.clone(), &self.tags)?;
        (serde_json::to_value(&after).ok()? == serde_json::to_value(&msg).ok()?).then_some(msg)
    }

    /// May a routed request name this tag? A PHI-scoped focus is refused.
    pub fn request_allowed(&self, msg: &ClientMsg) -> bool {
        let tag = match msg {
            ClientMsg::SessionModelGet { tag, .. }
            | ClientMsg::ActivitySnapshotRequest { tag, .. }
            | ClientMsg::SessionAttach { tag, .. }
            | ClientMsg::SessionDetach { tag, .. } => Some(tag.as_str()),
            _ => None,
        };
        tag.is_none_or(|t| !self.phi.tag_is_phi(t))
    }
}

/// Is `msg` one of the six reads the primary may route to a satellite?
fn is_routable_read(msg: &ClientMsg) -> bool {
    matches!(
        msg,
        ClientMsg::SessionList { .. }
            | ClientMsg::FocusList { .. }
            | ClientMsg::SessionModelGet { .. }
            | ClientMsg::ActivitySnapshotRequest { .. }
            | ClientMsg::SessionAttach { .. }
            | ClientMsg::SessionDetach { .. }
    )
}

// ── the tag key ───────────────────────────────────────────────────────────────

/// Load the satellite's random HMAC key for pseudonymous tags, creating it
/// (mode 0600) the first time. It never falls back to a default: with no key
/// the uplink does not publish.
pub fn load_or_create_tag_key(path: &Path) -> std::io::Result<[u8; 32]> {
    use std::io::Write;
    if let Ok(bytes) = std::fs::read(path) {
        if let Ok(key) = <[u8; 32]>::try_from(bytes.as_slice()) {
            return Ok(key);
        }
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "uplink tag key is not 32 bytes",
        ));
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut key = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut key);
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    match opts.open(path) {
        Ok(mut f) => {
            f.write_all(&key)?;
            Ok(key)
        }
        // Another start created it first.
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let bytes = std::fs::read(path)?;
            <[u8; 32]>::try_from(bytes.as_slice()).map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "uplink tag key is not 32 bytes",
                )
            })
        }
        Err(e) => Err(e),
    }
}

// ── the device-admin relay ────────────────────────────────────────────────────

type LocalTx = mpsc::UnboundedSender<ServerMsg>;

struct RelayedRequest {
    conn_key: String,
    original_id: String,
    tx: LocalTx,
}

#[derive(Default)]
struct RelayState {
    up: Option<mpsc::UnboundedSender<UplinkFrame>>,
    next_request: u64,
    /// Relayed verbs awaiting their answer, by the id sent upward.
    requests: HashMap<String, RelayedRequest>,
    /// Open pairings, by pairing id: who asked.
    pairings: HashMap<String, (String, LocalTx)>,
    /// Local clients waiting for a `DeviceList` answer.
    lists: VecDeque<(Instant, String, LocalTx)>,
    /// Local clients following the device list.
    subscribers: HashMap<String, LocalTx>,
    /// The effective level (narrowed locally) and where to pair from.
    level: Option<(SatelliteAdmin, Vec<String>)>,
    devices: Option<ServerMsg>,
}

/// Forwards the device-admin verbs of this satellite's local clients to the
/// primary, answers each to the client that asked, and tells local `devices`
/// subscribers their level. It holds no registry and executes nothing.
pub struct UplinkRelay {
    local: SatelliteAdmin,
    state: Mutex<RelayState>,
}

impl UplinkRelay {
    pub fn new(local: SatelliteAdmin) -> Arc<Self> {
        Arc::new(Self {
            local,
            state: Mutex::new(RelayState::default()),
        })
    }

    /// The level a verb is judged at: what the primary granted, narrowed by
    /// the local config. Before the primary has said, the local narrowing
    /// alone (the primary still judges everything).
    fn effective(&self, st: &RelayState) -> SatelliteAdmin {
        st.level.as_ref().map_or(self.local, |(l, _)| *l)
    }

    fn allowed(level: SatelliteAdmin, msg: &ClientMsg) -> bool {
        match msg {
            ClientMsg::DeviceList { .. } => level.rank() >= SatelliteAdmin::ReadOnly.rank(),
            ClientMsg::DeviceRevoke { .. } | ClientMsg::DevicePairCancel { .. } => {
                level.rank() >= SatelliteAdmin::RevokeOnly.rank()
            }
            // A device code needs `full`; an enrolment is never made from a satellite.
            ClientMsg::DevicePairStart { satellite, .. } => {
                satellite.is_none() && level == SatelliteAdmin::Full
            }
            // Levels are changed on the primary only.
            _ => false,
        }
    }

    /// A local client sent a device-admin verb: send it up (with its own
    /// request id and origin), or answer it at once.
    pub fn relay_verb(&self, mut msg: ClientMsg, conn_key: &str, tx: &LocalTx) {
        let original_id = admin_request_id(&msg);
        let refuse = |reason: &str| {
            let _ = tx.send(ServerMsg::DeviceAdminError {
                request_id: original_id.clone(),
                reason: reason.to_string(),
            });
        };
        let mut st = self.state.lock().unwrap();
        if !Self::allowed(self.effective(&st), &msg) {
            return refuse(NOT_PERMITTED);
        }
        let Some(up) = st.up.clone() else {
            return refuse(SERVER_UNREACHABLE);
        };
        st.next_request += 1;
        let up_id = format!("s{}", st.next_request);
        match &mut msg {
            ClientMsg::DevicePairStart {
                request_id, origin, ..
            }
            | ClientMsg::DevicePairCancel {
                request_id, origin, ..
            } => {
                *request_id = up_id.clone();
                *origin = Some(conn_key.to_string());
            }
            ClientMsg::DeviceRevoke { request_id, .. } => *request_id = up_id.clone(),
            ClientMsg::DeviceList { .. } => {}
            _ => return refuse(NOT_PERMITTED),
        }
        if matches!(msg, ClientMsg::DeviceList { .. }) {
            let now = Instant::now();
            st.lists
                .retain(|(t, _, _)| now.duration_since(*t) < LIST_TTL);
            st.lists.push_back((now, conn_key.to_string(), tx.clone()));
        } else {
            st.requests.insert(
                up_id,
                RelayedRequest {
                    conn_key: conn_key.to_string(),
                    original_id: original_id.clone(),
                    tx: tx.clone(),
                },
            );
        }
        if up.send(UplinkFrame::Client { msg }).is_err() {
            drop(st);
            refuse(SERVER_UNREACHABLE);
        }
    }

    /// A local client now follows the device list: tell it the level and the
    /// latest list (when known).
    pub fn subscribe_devices(&self, conn_key: &str, tx: &LocalTx) {
        let mut st = self.state.lock().unwrap();
        st.subscribers.insert(conn_key.to_string(), tx.clone());
        if let Some((level, pair_from)) = st.level.clone() {
            let _ = tx.send(ServerMsg::DeviceAdminLevel { level, pair_from });
        }
        if let Some(devices) = st.devices.clone() {
            let _ = tx.send(devices);
        }
    }

    /// A local client went away: it follows nothing, and a pairing it started
    /// is cancelled on the primary.
    pub fn drop_connection(&self, conn_key: &str) {
        let mut st = self.state.lock().unwrap();
        st.subscribers.remove(conn_key);
        st.lists.retain(|(_, k, _)| k != conn_key);
        st.requests.retain(|_, r| r.conn_key != conn_key);
        let owned: Vec<String> = st
            .pairings
            .iter()
            .filter(|(_, (k, _))| k == conn_key)
            .map(|(id, _)| id.clone())
            .collect();
        for pairing_id in owned {
            st.pairings.remove(&pairing_id);
            st.next_request += 1;
            let request_id = format!("s{}", st.next_request);
            if let Some(up) = &st.up {
                let _ = up.send(UplinkFrame::Client {
                    msg: ClientMsg::DevicePairCancel {
                        request_id,
                        pairing_id,
                        origin: Some(conn_key.to_string()),
                    },
                });
            }
        }
    }

    /// The uplink is connected (`Some`) or not (`None`). When it drops, every
    /// relayed open pairing is told `connection_lost` and every verb still
    /// waiting is answered `server_unreachable`.
    pub fn set_up(&self, up: Option<mpsc::UnboundedSender<UplinkFrame>>) {
        let mut st = self.state.lock().unwrap();
        let connected = up.is_some();
        st.up = up;
        if connected {
            return;
        }
        for (pairing_id, (_, tx)) in st.pairings.drain().collect::<Vec<_>>() {
            let _ = tx.send(ServerMsg::DevicePairOutcome {
                pairing_id,
                outcome: crate::ipc::devices::PairOutcomeKind::ConnectionLost,
                name: None,
                kind: None,
                replaced: false,
            });
        }
        for (_, r) in st.requests.drain().collect::<Vec<_>>() {
            let _ = r.tx.send(ServerMsg::DeviceAdminError {
                request_id: r.original_id,
                reason: SERVER_UNREACHABLE.to_string(),
            });
        }
        st.lists.clear();
        // What the primary last said is stale until it says it again.
        st.level = None;
    }

    /// A frame the primary wrote to this uplink: deliver it to the one local
    /// client it answers (or to every `devices` follower).
    pub fn from_primary(&self, msg: ServerMsg) {
        let mut st = self.state.lock().unwrap();
        match msg {
            ServerMsg::DevicePairing {
                request_id,
                pairing_id,
                code,
                server_url,
                expires_at,
            } => {
                if let Some(r) = st.requests.remove(&request_id) {
                    st.pairings
                        .insert(pairing_id.clone(), (r.conn_key, r.tx.clone()));
                    let _ = r.tx.send(ServerMsg::DevicePairing {
                        request_id: r.original_id,
                        pairing_id,
                        code,
                        server_url,
                        expires_at,
                    });
                }
            }
            ServerMsg::DevicePairOutcome {
                pairing_id,
                outcome,
                name,
                kind,
                replaced,
            } => {
                if let Some((_, tx)) = st.pairings.remove(&pairing_id) {
                    let _ = tx.send(ServerMsg::DevicePairOutcome {
                        pairing_id,
                        outcome,
                        name,
                        kind,
                        replaced,
                    });
                }
            }
            ServerMsg::DeviceRevoked {
                request_id,
                device_id,
                was_connected,
            } => {
                if let Some(r) = st.requests.remove(&request_id) {
                    let _ = r.tx.send(ServerMsg::DeviceRevoked {
                        request_id: r.original_id,
                        device_id,
                        was_connected,
                    });
                }
            }
            ServerMsg::DeviceAdminError { request_id, reason } => {
                if let Some(r) = st.requests.remove(&request_id) {
                    let _ = r.tx.send(ServerMsg::DeviceAdminError {
                        request_id: r.original_id,
                        reason,
                    });
                }
            }
            ServerMsg::Devices { devices, hosts } => {
                let frame = ServerMsg::Devices { devices, hosts };
                st.devices = Some(frame.clone());
                let mut sent: HashSet<String> = HashSet::new();
                for (key, tx) in &st.subscribers {
                    let _ = tx.send(frame.clone());
                    sent.insert(key.clone());
                }
                let now = Instant::now();
                let pending: Vec<_> = st.lists.drain(..).collect();
                for (t, key, tx) in pending {
                    if now.duration_since(t) < LIST_TTL && !sent.contains(&key) {
                        let _ = tx.send(frame.clone());
                    }
                }
            }
            ServerMsg::DeviceAdminLevel { level, pair_from } => {
                let effective = level.min_with(self.local);
                st.level = Some((effective, pair_from.clone()));
                for tx in st.subscribers.values() {
                    let _ = tx.send(ServerMsg::DeviceAdminLevel {
                        level: effective,
                        pair_from: pair_from.clone(),
                    });
                }
            }
            // Anything else the primary wrote (Welcome, Hosts, a refusal) is
            // not for a local client.
            _ => {}
        }
    }
}

fn admin_request_id(msg: &ClientMsg) -> String {
    match msg {
        ClientMsg::DevicePairStart { request_id, .. }
        | ClientMsg::DevicePairCancel { request_id, .. }
        | ClientMsg::DeviceList { request_id }
        | ClientMsg::DeviceRevoke { request_id, .. }
        | ClientMsg::DeviceSetAdmin { request_id, .. } => request_id.clone(),
        _ => String::new(),
    }
}

// ── the connection ────────────────────────────────────────────────────────────

/// What the uplink task needs from the daemon.
pub(super) struct Env {
    pub(super) setup: SatelliteSetup,
    /// Where the HMAC key for pseudonymous tags lives (created at first start).
    pub(super) tag_key_path: std::path::PathBuf,
    pub(super) tx: broadcast::Sender<ServerMsg>,
    pub(super) sensitive: SensitiveTags,
    pub(super) dispatch: LocalDispatch,
    pub(super) relay: Arc<UplinkRelay>,
}

/// The live connection's channels and the replay cache, under one lock so a
/// frame is either in the replay or sent live, never both and never neither.
struct Shared {
    forwarder: Forwarder,
    cache: BTreeMap<String, ServerMsg>,
    publish: Option<mpsc::UnboundedSender<UplinkFrame>>,
}

/// Start the uplink: a task that filters this daemon's broadcasts as they
/// happen, and one that keeps a connection to the primary.
pub(super) fn spawn(env: Env) {
    let key_path = env.tag_key_path.clone();
    let host_key = match load_or_create_tag_key(&key_path) {
        Ok(k) => k,
        Err(e) => {
            error!(
                "uplink disabled: the tag key at {} is unusable: {e}",
                key_path.display()
            );
            return;
        }
    };
    let forwarder = Forwarder::new(
        env.setup.host.clone(),
        env.setup.uplink.egress,
        host_key,
        env.sensitive.clone(),
        env.setup.phi_repos.clone(),
        env.setup.uplink.publish_topics.clone(),
    );
    let shared = Arc::new(Mutex::new(Shared {
        forwarder,
        cache: BTreeMap::new(),
        publish: None,
    }));
    tokio::spawn(filter_task(env.tx.subscribe(), Arc::clone(&shared)));
    tokio::spawn(connection_loop(env, shared));
}

async fn filter_task(mut rx: broadcast::Receiver<ServerMsg>, shared: Arc<Mutex<Shared>>) {
    loop {
        match rx.recv().await {
            Ok(msg) => {
                let key = cache_key(&msg);
                let mut sh = shared.lock().unwrap();
                match sh.forwarder.publish(msg) {
                    Some(out) => {
                        if let Some(k) = key {
                            if sh.cache.len() < MAX_CACHED || sh.cache.contains_key(&k) {
                                sh.cache.insert(k, out.clone());
                            }
                        }
                        if let Some(p) = &sh.publish {
                            let _ = p.send(UplinkFrame::Publish { msg: out });
                        }
                    }
                    None => {
                        // A frame that is now kept home must not linger in the replay.
                        if let Some(k) = key {
                            sh.cache.remove(&k);
                        }
                    }
                }
            }
            Err(broadcast::error::RecvError::Lagged(n)) => {
                debug!("uplink forwarder lagged {n} broadcasts");
            }
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}

/// The wait after a failed attempt doubles, up to a minute.
fn next_backoff(current: Duration) -> Duration {
    (current * 2).min(BACKOFF_CAP)
}

enum SessionEnd {
    /// The primary does not advertise `"uplink"`.
    NoUplink,
    /// The connection ran (it was admitted) and then ended.
    Ended,
    /// It never got going.
    Failed(String),
}

async fn connection_loop(env: Env, shared: Arc<Mutex<Shared>>) {
    let mut backoff = BACKOFF_START;
    loop {
        let wait = match run_session(&env, &shared).await {
            SessionEnd::NoUplink => {
                warn!("the primary does not advertise uplink support; trying again in 10 minutes");
                NO_UPLINK_RETRY
            }
            SessionEnd::Ended => {
                info!("uplink to the primary closed; reconnecting");
                backoff = BACKOFF_START;
                backoff
            }
            SessionEnd::Failed(why) => {
                warn!("uplink could not connect: {why}; retrying in {backoff:?}");
                let w = backoff;
                backoff = next_backoff(backoff);
                w
            }
        };
        tokio::time::sleep(wait).await;
    }
}

fn read_token(path: &Path) -> Result<String, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read the token at {}: {e}", path.display()))?;
    let token = raw.trim().to_string();
    if token.is_empty() {
        return Err(format!(
            "the token file {} is empty; run `nostromo uplink pair`",
            path.display()
        ));
    }
    Ok(token)
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn send_frame(ws: &mut Ws, frame: &UplinkFrame) -> Result<(), String> {
    let text = serde_json::to_string(frame).map_err(|e| e.to_string())?;
    ws.send(Message::Text(text))
        .await
        .map_err(|e| e.to_string())
}

async fn run_session(env: &Env, shared: &Arc<Mutex<Shared>>) -> SessionEnd {
    let token = match read_token(&env.setup.uplink.token_path) {
        Ok(t) => t,
        Err(e) => return SessionEnd::Failed(e),
    };
    let mut req = match env.setup.uplink.url.as_str().into_client_request() {
        Ok(r) => r,
        Err(e) => return SessionEnd::Failed(format!("bad uplink url: {e}")),
    };
    // Never an `Origin` header: the primary refuses a browser-shaped upgrade.
    match HeaderValue::from_str(&format!("Bearer {token}")) {
        Ok(v) => {
            req.headers_mut().insert("Authorization", v);
        }
        Err(_) => return SessionEnd::Failed("the token is not a valid header value".into()),
    }
    let mut ws = match tokio_tungstenite::connect_async(req).await {
        Ok((ws, _)) => ws,
        Err(e) => return SessionEnd::Failed(e.to_string()),
    };

    let hello = UplinkFrame::Client {
        msg: ClientMsg::Hello {
            client_id: format!("satellite-{}", env.setup.host),
            protocol_version: PROTOCOL_VERSION,
            client_kind: None,
            // Declares nothing: this daemon attaches to nothing on the primary.
            capabilities: vec![],
            role: Some(HelloRole::Satellite {
                host: env.setup.host.clone(),
                egress: env.setup.uplink.egress,
            }),
        },
    };
    if let Err(e) = send_frame(&mut ws, &hello).await {
        return SessionEnd::Failed(e);
    }
    // The primary's `Welcome`, which says whether it serves uplinks.
    let welcome = tokio::time::timeout(WELCOME_TIMEOUT, async {
        loop {
            match ws.next().await {
                Some(Ok(Message::Text(t))) => {
                    if let Ok(UplinkFrame::Server {
                        msg: ServerMsg::Welcome { features, .. },
                    }) = serde_json::from_str::<UplinkFrame>(&t)
                    {
                        return Ok(features);
                    }
                    // A refusal (Unauthorized) or anything else before it.
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&t) {
                        let ty = v
                            .get("msg")
                            .unwrap_or(&v)
                            .get("type")
                            .and_then(|t| t.as_str())
                            .unwrap_or("");
                        if ty == "unauthorized" {
                            return Err(
                                "the primary refused this satellite (unauthorized)".to_string()
                            );
                        }
                    }
                }
                Some(Ok(Message::Close(f))) => {
                    return Err(format!("closed by the primary: {f:?}"));
                }
                Some(Ok(_)) => {}
                Some(Err(e)) => return Err(e.to_string()),
                None => return Err("closed before Welcome".to_string()),
            }
        }
    })
    .await;
    let features = match welcome {
        Err(_) => return SessionEnd::Failed("no Welcome from the primary".into()),
        Ok(Err(e)) => return SessionEnd::Failed(e),
        Ok(Ok(f)) => f,
    };
    if !features.iter().any(|f| f == FEATURE_UPLINK) {
        let _ = ws.close(None).await;
        return SessionEnd::NoUplink;
    }
    // A satellite publishes; the only thing it follows is the device list.
    let subscribe = UplinkFrame::Client {
        msg: ClientMsg::Subscribe {
            topics: vec![Topic::Devices],
            renders_decisions: false,
            renders_approvals: false,
            capabilities: vec![],
            operator_nonce: None,
        },
    };
    if let Err(e) = send_frame(&mut ws, &subscribe).await {
        return SessionEnd::Failed(e);
    }

    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<UplinkFrame>();
    let (pub_tx, mut pub_rx) = mpsc::unbounded_channel::<UplinkFrame>();
    {
        // Replay what is retained, then go live, atomically.
        let mut sh = shared.lock().unwrap();
        for msg in sh.cache.values() {
            let _ = pub_tx.send(UplinkFrame::Publish { msg: msg.clone() });
        }
        sh.publish = Some(pub_tx.clone());
    }
    env.relay.set_up(Some(out_tx.clone()));
    info!(host = %env.setup.host, "uplink connected");

    let mut routed = RoutedReads::default();
    let mut pace = tokio::time::interval(PUBLISH_SPACING);
    pace.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut may_publish = true;
    let personal = env.setup.uplink.egress == Egress::Personal;
    let reason: Result<(), String> = loop {
        tokio::select! {
            _ = pace.tick() => may_publish = true,
            frame = pub_rx.recv(), if may_publish => {
                let Some(frame) = frame else { break Ok(()) };
                may_publish = false;
                if let Err(e) = send_frame(&mut ws, &frame).await { break Err(e); }
            }
            frame = out_rx.recv() => {
                let Some(frame) = frame else { break Ok(()) };
                if let Err(e) = send_frame(&mut ws, &frame).await { break Err(e); }
            }
            incoming = ws.next() => {
                match incoming {
                    Some(Ok(Message::Text(t))) => {
                        match serde_json::from_str::<UplinkFrame>(&t) {
                            Ok(UplinkFrame::Server { msg }) => env.relay.from_primary(msg),
                            Ok(UplinkFrame::Request { id, msg }) => {
                                handle_request(env, shared, &mut routed, &out_tx, personal, id, msg);
                            }
                            // `client`, `publish` and `reply` only ever go upward.
                            Ok(_) | Err(_) => note_dropped("a frame that is not a server or request envelope"),
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break Ok(()),
                    Some(Ok(_)) => {}
                    Some(Err(e)) => break Err(e.to_string()),
                }
            }
        }
    };

    // Whatever ended it: nothing is published, every pairing is told it is
    // lost, and every routed read's local connection is closed.
    shared.lock().unwrap().publish = None;
    env.relay.set_up(None);
    routed.close_all(&env.dispatch);
    let _ = ws.close(None).await;
    match reason {
        Ok(()) => SessionEnd::Ended,
        Err(e) => {
            debug!("uplink ended: {e}");
            SessionEnd::Ended
        }
    }
}

/// One warning per kind of unexpected frame per hour.
fn note_dropped(what: &'static str) {
    static SEEN: Mutex<Option<HashMap<&'static str, Instant>>> = Mutex::new(None);
    let mut seen = SEEN.lock().unwrap();
    let map = seen.get_or_insert_with(HashMap::new);
    let now = Instant::now();
    let due = map
        .get(what)
        .is_none_or(|t| now.duration_since(*t) >= Duration::from_secs(3600));
    if due {
        map.insert(what, now);
        warn!("uplink dropped {what} from the primary");
    }
}

// ── routed reads ──────────────────────────────────────────────────────────────

/// The local connections standing in for requesters on the primary, by the
/// opaque request id: `uplink:<id>`.
#[derive(Default)]
struct RoutedReads {
    live: HashMap<String, tokio::task::JoinHandle<()>>,
}

impl RoutedReads {
    fn close(&mut self, dispatch: &LocalDispatch, id: &str) {
        if let Some(task) = self.live.remove(id) {
            task.abort();
        }
        dispatch.close_routed(&format!("uplink:{id}"));
    }

    fn close_all(&mut self, dispatch: &LocalDispatch) {
        let ids: Vec<String> = self.live.keys().cloned().collect();
        for id in ids {
            self.close(dispatch, &id);
        }
    }
}

fn handle_request(
    env: &Env,
    shared: &Arc<Mutex<Shared>>,
    routed: &mut RoutedReads,
    out: &mpsc::UnboundedSender<UplinkFrame>,
    personal: bool,
    id: String,
    msg: ClientMsg,
) {
    // Only a `personal` satellite answers, and only the six read verbs. A
    // `DecisionAnswer`, `ApprovalAnswer`, `MotherResume`, ... is never run.
    if !personal || !is_routable_read(&msg) {
        note_dropped("a request that is not a routed read for a personal satellite");
        return;
    }
    // A closed id's finished tasks are forgotten.
    routed.live.retain(|_, t| !t.is_finished());
    let key = format!("uplink:{id}");
    if matches!(msg, ClientMsg::SessionDetach { .. }) {
        env.dispatch
            .run_routed(msg, &key, &mpsc::unbounded_channel().0);
        routed.close(&env.dispatch, &id);
        return;
    }
    let refused = !shared.lock().unwrap().forwarder.request_allowed(&msg);
    let attach = matches!(msg, ClientMsg::SessionAttach { .. });
    let (tx, mut rx) = mpsc::unbounded_channel::<ServerMsg>();
    if refused {
        let _ = tx.send(withheld_msg());
    } else if !routed.live.contains_key(&id) {
        env.dispatch.open_routed(&key, &tx);
    }
    let dispatch = env.dispatch.clone();
    let shared = Arc::clone(shared);
    let out = out.clone();
    let reply_id = id.clone();
    let key_for_task = key.clone();
    let is_refused = refused;
    if !refused {
        env.dispatch.run_routed(msg, &key, &tx);
    }
    let task = tokio::spawn(async move {
        let started = Instant::now();
        loop {
            let next = if attach {
                rx.recv().await
            } else {
                let left = ROUTED_TTL.saturating_sub(started.elapsed());
                match tokio::time::timeout(left, rx.recv()).await {
                    Ok(m) => m,
                    Err(_) => None,
                }
            };
            let Some(m) = next else { break };
            let is_refusal = matches!(m, ServerMsg::Error { .. } | ServerMsg::Withheld { .. });
            let filtered = shared.lock().unwrap().forwarder.reply(m);
            if let Some(m) = filtered {
                let _ = out.send(UplinkFrame::Reply {
                    id: reply_id.clone(),
                    msg: m,
                });
            }
            // A refusal ends the read: nothing more will be asked of it.
            if is_refusal || is_refused {
                break;
            }
        }
        dispatch.close_routed(&key_for_task);
    });
    if let Some(old) = routed.live.insert(id, task) {
        old.abort();
    }
    drop(tx);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::devices::DeviceSummary;

    fn relay_pair(
        local: SatelliteAdmin,
    ) -> (
        Arc<UplinkRelay>,
        mpsc::UnboundedReceiver<UplinkFrame>,
        LocalTx,
        mpsc::UnboundedReceiver<ServerMsg>,
    ) {
        let relay = UplinkRelay::new(local);
        let (up_tx, up_rx) = mpsc::unbounded_channel();
        relay.set_up(Some(up_tx));
        let (tx, rx) = mpsc::unbounded_channel();
        (relay, up_rx, tx, rx)
    }

    fn level(relay: &UplinkRelay, l: SatelliteAdmin) {
        relay.from_primary(ServerMsg::DeviceAdminLevel {
            level: l,
            pair_from: vec![],
        });
    }

    #[test]
    fn a_verb_goes_up_with_its_own_id_and_origin_and_the_answer_comes_back_under_the_original() {
        let (relay, mut up, tx, mut rx) = relay_pair(SatelliteAdmin::Full);
        level(&relay, SatelliteAdmin::Full);
        relay.relay_verb(
            ClientMsg::DevicePairStart {
                request_id: "mine".into(),
                name_hint: None,
                satellite: None,
                admin: None,
                egress: None,
                origin: Some("forged".into()),
            },
            "conn-1",
            &tx,
        );
        let UplinkFrame::Client {
            msg: ClientMsg::DevicePairStart {
                request_id, origin, ..
            },
        } = up.try_recv().unwrap()
        else {
            panic!("expected a relayed DevicePairStart")
        };
        assert_ne!(request_id, "mine");
        assert_eq!(
            origin.as_deref(),
            Some("conn-1"),
            "the origin is ours, never the client's"
        );
        relay.from_primary(ServerMsg::DevicePairing {
            request_id,
            pairing_id: "p1".into(),
            code: "123456".into(),
            server_url: "nostromo://pair".into(),
            expires_at: chrono::Utc::now(),
        });
        match rx.try_recv().unwrap() {
            ServerMsg::DevicePairing { request_id, .. } => assert_eq!(request_id, "mine"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn with_the_uplink_down_a_verb_is_refused_at_once() {
        let relay = UplinkRelay::new(SatelliteAdmin::Full);
        let (tx, mut rx) = mpsc::unbounded_channel();
        relay.relay_verb(
            ClientMsg::DeviceList {
                request_id: "r".into(),
            },
            "c",
            &tx,
        );
        match rx.try_recv().unwrap() {
            ServerMsg::DeviceAdminError { request_id, reason } => {
                assert_eq!(
                    (request_id.as_str(), reason.as_str()),
                    ("r", SERVER_UNREACHABLE)
                );
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn dropping_the_uplink_tells_every_open_pairing_connection_lost() {
        let (relay, mut up, tx, mut rx) = relay_pair(SatelliteAdmin::Full);
        relay.relay_verb(
            ClientMsg::DevicePairStart {
                request_id: "a".into(),
                name_hint: None,
                satellite: None,
                admin: None,
                egress: None,
                origin: None,
            },
            "c",
            &tx,
        );
        let UplinkFrame::Client {
            msg: ClientMsg::DevicePairStart { request_id, .. },
        } = up.try_recv().unwrap()
        else {
            panic!()
        };
        relay.from_primary(ServerMsg::DevicePairing {
            request_id,
            pairing_id: "p9".into(),
            code: "1".into(),
            server_url: "u".into(),
            expires_at: chrono::Utc::now(),
        });
        let _ = rx.try_recv().unwrap();
        relay.set_up(None);
        match rx.try_recv().unwrap() {
            ServerMsg::DevicePairOutcome {
                pairing_id,
                outcome,
                ..
            } => {
                assert_eq!(pairing_id, "p9");
                assert_eq!(
                    outcome,
                    crate::ipc::devices::PairOutcomeKind::ConnectionLost
                );
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_local_narrowing_lowers_the_level_and_the_verbs_it_allows() {
        let (relay, mut up, tx, mut rx) = relay_pair(SatelliteAdmin::ReadOnly);
        let (sub_tx, mut sub_rx) = mpsc::unbounded_channel();
        relay.subscribe_devices("s", &sub_tx);
        level(&relay, SatelliteAdmin::Full);
        match sub_rx.try_recv().unwrap() {
            ServerMsg::DeviceAdminLevel { level, .. } => {
                assert_eq!(level, SatelliteAdmin::ReadOnly, "the lower of the two");
            }
            other => panic!("{other:?}"),
        }
        relay.relay_verb(
            ClientMsg::DeviceRevoke {
                request_id: "x".into(),
                device: "phone".into(),
            },
            "c",
            &tx,
        );
        assert!(up.try_recv().is_err(), "nothing was sent up");
        match rx.try_recv().unwrap() {
            ServerMsg::DeviceAdminError { reason, .. } => assert_eq!(reason, NOT_PERMITTED),
            other => panic!("{other:?}"),
        }
        relay.relay_verb(
            ClientMsg::DeviceList {
                request_id: "l".into(),
            },
            "c",
            &tx,
        );
        assert!(matches!(
            up.try_recv().unwrap(),
            UplinkFrame::Client {
                msg: ClientMsg::DeviceList { .. }
            }
        ));
    }

    #[test]
    fn set_admin_and_enrolment_are_never_relayed_at_any_level() {
        let (relay, mut up, tx, mut rx) = relay_pair(SatelliteAdmin::Full);
        level(&relay, SatelliteAdmin::Full);
        relay.relay_verb(
            ClientMsg::DeviceSetAdmin {
                request_id: "a".into(),
                host: "kobe".into(),
                admin: SatelliteAdmin::Full,
            },
            "c",
            &tx,
        );
        relay.relay_verb(
            ClientMsg::DevicePairStart {
                request_id: "b".into(),
                name_hint: None,
                satellite: Some("x".into()),
                admin: None,
                egress: None,
                origin: None,
            },
            "c",
            &tx,
        );
        assert!(up.try_recv().is_err());
        for _ in 0..2 {
            assert!(matches!(
                rx.try_recv().unwrap(),
                ServerMsg::DeviceAdminError { reason, .. } if reason == NOT_PERMITTED
            ));
        }
    }

    #[test]
    fn an_off_satellite_still_hears_that_it_is_off_and_devices_reach_only_followers() {
        let (relay, _up, _tx, _rx) = relay_pair(SatelliteAdmin::Full);
        let (a_tx, mut a_rx) = mpsc::unbounded_channel();
        let (b_tx, mut b_rx) = mpsc::unbounded_channel();
        relay.subscribe_devices("a", &a_tx);
        level(&relay, SatelliteAdmin::Off);
        assert!(matches!(
            a_rx.try_recv().unwrap(),
            ServerMsg::DeviceAdminLevel {
                level: SatelliteAdmin::Off,
                ..
            }
        ));
        relay.from_primary(ServerMsg::Devices {
            devices: Vec::<DeviceSummary>::new(),
            hosts: vec![],
        });
        assert!(matches!(
            a_rx.try_recv().unwrap(),
            ServerMsg::Devices { .. }
        ));
        // A client that subscribes later is told the retained level and list.
        relay.subscribe_devices("b", &b_tx);
        assert!(matches!(
            b_rx.try_recv().unwrap(),
            ServerMsg::DeviceAdminLevel { .. }
        ));
        assert!(matches!(
            b_rx.try_recv().unwrap(),
            ServerMsg::Devices { .. }
        ));
    }

    #[test]
    fn closing_a_local_client_cancels_its_pairing_upstream() {
        let (relay, mut up, tx, mut rx) = relay_pair(SatelliteAdmin::Full);
        level(&relay, SatelliteAdmin::Full);
        relay.relay_verb(
            ClientMsg::DevicePairStart {
                request_id: "a".into(),
                name_hint: None,
                satellite: None,
                admin: None,
                egress: None,
                origin: None,
            },
            "conn-1",
            &tx,
        );
        let UplinkFrame::Client {
            msg: ClientMsg::DevicePairStart { request_id, .. },
        } = up.try_recv().unwrap()
        else {
            panic!()
        };
        relay.from_primary(ServerMsg::DevicePairing {
            request_id,
            pairing_id: "p1".into(),
            code: "1".into(),
            server_url: "u".into(),
            expires_at: chrono::Utc::now(),
        });
        let _ = rx.try_recv();
        relay.drop_connection("conn-1");
        match up.try_recv().unwrap() {
            UplinkFrame::Client {
                msg:
                    ClientMsg::DevicePairCancel {
                        pairing_id, origin, ..
                    },
            } => {
                assert_eq!(pairing_id, "p1");
                assert_eq!(origin.as_deref(), Some("conn-1"));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_tag_key_is_created_once_with_mode_0600_and_reloaded() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub").join("uplink-tag-key");
        let a = load_or_create_tag_key(&path).unwrap();
        let b = load_or_create_tag_key(&path).unwrap();
        assert_eq!(a, b);
        assert_ne!(a, [0u8; 32]);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        std::fs::write(&path, b"short").unwrap();
        assert!(
            load_or_create_tag_key(&path).is_err(),
            "never a default key"
        );
    }

    // ── the egress filter ────────────────────────────────────────────────────

    fn key() -> [u8; 32] {
        [7u8; 32]
    }

    fn forwarder(egress: Egress) -> Forwarder {
        Forwarder::new(
            "kobe".into(),
            egress,
            key(),
            SensitiveTags::default(),
            vec!["admin-portal".into(), "referral-monitor".into()],
            None,
        )
    }

    fn job(id: &str, repo: &str) -> serde_json::Value {
        serde_json::json!({
            "id": id, "state": "awaiting", "title": "MARKER-title", "repo": repo,
            "question": "MARKER-question", "plan_path": "/MARKER/plan.md",
            "activity": "gate_hold",
        })
    }

    fn jobs_msg(jobs: Vec<serde_json::Value>) -> ServerMsg {
        serde_json::from_value(serde_json::json!({
            "type": "mother_jobs", "jobs": jobs,
        }))
        .unwrap()
    }

    fn focus(tag: &str, path: &str) -> crate::ipc::protocol::FocusMeta {
        serde_json::from_value(serde_json::json!({
            "tag": tag, "display_name": "MARKER-name", "agent_name": "cody",
            "is_built_in": false, "project_path": path,
        }))
        .unwrap()
    }

    #[test]
    fn a_work_satellites_frames_carry_its_host_and_none_of_its_text() {
        let mut f = forwarder(Egress::Work);
        let out = f
            .publish(jobs_msg(vec![job("0123456789abcdef", "/code/billing")]))
            .expect("a metadata job list is published");
        let json = serde_json::to_string(&out).unwrap();
        assert!(!json.contains("MARKER"), "{json}");
        assert_eq!(server_msg_host(&out), Some(Some("kobe")));
        // Whatever it sends, the primary's own check accepts.
        let record = SatelliteRecord {
            name: "kobe".into(),
            egress: Egress::Work,
        };
        assert!(ingest_from_satellite(&record, out, &SensitiveTags::default()).is_ok());
    }

    #[test]
    fn nothing_administrative_or_host_less_is_ever_published() {
        for egress in [Egress::Work, Egress::Personal] {
            let mut f = forwarder(egress);
            let frames: Vec<ServerMsg> = [
                serde_json::json!({"type": "devices", "devices": [], "hosts": []}),
                serde_json::json!({"type": "device_admin_level", "level": "full", "pair_from": ["kobe"]}),
                serde_json::json!({"type": "hosts", "hosts": []}),
                serde_json::json!({"type": "pong"}),
                serde_json::json!({"type": "error", "message": "x"}),
                serde_json::json!({"type": "device_unpaired"}),
                serde_json::json!({"type": "unauthorized", "reason": "role"}),
                serde_json::json!({"type": "device_admin_error", "request_id": "a", "reason": "b"}),
                serde_json::json!({"type": "daemon_reconnected"}),
            ]
            .into_iter()
            .filter_map(|v| serde_json::from_value(v).ok())
            .collect();
            assert!(frames.len() >= 7, "the constructors must decode");
            for m in frames {
                assert!(f.publish(m.clone()).is_none(), "{egress:?} published {m:?}");
            }
        }
    }

    #[test]
    fn a_personal_satellite_keeps_phi_repo_work_and_sensitive_focuses_home() {
        let mut f = forwarder(Egress::Personal);
        // Learn which focus is PHI from the focus list passing through.
        let list = ServerMsg::FocusListResp {
            focuses: vec![
                focus("cody-a", "/code/admin-portal"),
                focus("cody-b", "/code/blog"),
            ],
            host: None,
        };
        let out = f.publish(list).expect("the ordinary focus is published");
        match out {
            ServerMsg::FocusListResp { focuses, host } => {
                assert_eq!(host.as_deref(), Some("kobe"));
                assert_eq!(
                    focuses.iter().map(|f| f.tag.as_str()).collect::<Vec<_>>(),
                    ["cody-b"]
                );
            }
            other => panic!("{other:?}"),
        }
        // A frame about the PHI focus is not sent at all.
        let phi_count = ServerMsg::ApprovalPending {
            tag: "cody-a".into(),
            count: 2,
            host: None,
        };
        assert!(f.publish(phi_count).is_none());
        let ok_count = ServerMsg::ApprovalPending {
            tag: "cody-b".into(),
            count: 1,
            host: None,
        };
        assert!(f.publish(ok_count).is_some());
        // A Fred count is withheld by the network filter.
        let fred = ServerMsg::ApprovalPending {
            tag: "fred".into(),
            count: 9,
            host: None,
        };
        assert!(f.publish(fred).is_none());
        // A PHI job leaves the list; an ordinary one stays, in full.
        let out = f
            .publish(jobs_msg(vec![
                job("aaaaaaaa", "/code/referral-monitor"),
                job("bbbbbbbb", "/code/blog"),
            ]))
            .unwrap();
        match out {
            ServerMsg::MotherJobs { jobs, .. } => {
                assert_eq!(
                    jobs.iter().map(|j| j.id.as_str()).collect::<Vec<_>>(),
                    ["bbbbbbbb"]
                );
                assert_eq!(jobs[0].title, "MARKER-title", "personal sends its text");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn publish_topics_narrow_what_is_sent() {
        let mut f = Forwarder::new(
            "kobe".into(),
            Egress::Personal,
            key(),
            SensitiveTags::default(),
            vec![],
            Some(vec![Topic::MotherJobs]),
        );
        assert!(f
            .publish(jobs_msg(vec![job("bbbbbbbb", "/code/blog")]))
            .is_some());
        let count = ServerMsg::ApprovalPending {
            tag: "cody-b".into(),
            count: 1,
            host: None,
        };
        assert!(f.publish(count).is_none());
    }

    #[test]
    fn only_a_personal_satellite_answers_and_a_reply_is_stamped_and_phi_free() {
        let work = forwarder(Egress::Work);
        let list = ServerMsg::SessionListResp {
            sessions: vec![],
            host: None,
        };
        assert!(work.reply(list.clone()).is_none());
        let mut personal = forwarder(Egress::Personal);
        match personal.reply(list).expect("a personal reply") {
            ServerMsg::SessionListResp { host, .. } => assert_eq!(host.as_deref(), Some("kobe")),
            other => panic!("{other:?}"),
        }
        personal.phi.observe(&ServerMsg::FocusCreated {
            meta: focus("cody-a", "/code/admin-portal"),
            host: None,
        });
        assert!(!personal.request_allowed(&ClientMsg::SessionAttach {
            tag: "cody-a".into(),
            host: None
        }));
        assert!(personal.request_allowed(&ClientMsg::SessionAttach {
            tag: "cody-b".into(),
            host: None
        }));
    }

    #[test]
    fn the_reconnect_backoff_doubles_to_a_minute_and_stays() {
        let mut b = BACKOFF_START;
        let mut seen = vec![b.as_secs()];
        for _ in 0..8 {
            b = next_backoff(b);
            seen.push(b.as_secs());
        }
        assert_eq!(seen, [1, 2, 4, 8, 16, 32, 60, 60, 60]);
    }

    #[test]
    fn only_the_six_reads_are_routable() {
        assert!(is_routable_read(&ClientMsg::SessionList { host: None }));
        assert!(is_routable_read(&ClientMsg::FocusList { host: None }));
        assert!(!is_routable_read(&ClientMsg::Ping));
        assert!(!is_routable_read(&ClientMsg::MotherResume {
            job_id: "j".into(),
            answer: "a".into()
        }));
    }
}
