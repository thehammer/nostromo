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
use crate::ipc::router::{
    ingest_from_satellite, server_msg_host, server_msg_tag, MsgTag, SatelliteRecord,
};
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
/// Frames queued for the socket while connected: published state, and
/// verbs and routed replies. Publishing is paced at 40/s, so a full queue
/// means the socket is stuck; a frame that does not fit is dropped (state
/// frames are re-sent on change and replayed on reconnect), never waited for.
const PUBLISH_QUEUE: usize = 1024;
const OUT_QUEUE: usize = 256;
/// Routed reads one uplink serves at once; a further one is refused.
const MAX_ROUTED: usize = 32;
/// The longest routed-request id accepted.
const MAX_ROUTED_ID: usize = 128;
/// A session must have stayed up this long before the reconnect backoff resets.
const STABLE_AFTER: Duration = Duration::from_secs(30);

/// The refusal a verb gets when the effective level does not allow it, and
/// when the uplink is down.
pub const NOT_PERMITTED: &str = "not_permitted_on_this_mac";
pub const SERVER_UNREACHABLE: &str = "server_unreachable";

// ── the egress filter ─────────────────────────────────────────────────────────

/// Which focus tags belong to a PHI repo, and which tags are known at all.
///
/// The authority is the daemon's focus registry, read before every decision
/// (see [`PhiScope::refresh`]); the focus frames that pass through update it
/// too. A tag the registry does not hold cannot be classified, so a frame or a
/// routed read naming it is refused: this fails closed.
#[derive(Debug, Clone)]
pub struct PhiScope {
    repos: Vec<String>,
    /// Every tag in the registry.
    known: HashSet<String>,
    /// The subset whose project is a PHI repo.
    phi: HashSet<String>,
}

/// A repo or project name in comparable form: lower-case, `-` for spaces and
/// underscores, no `.git` suffix.
fn norm(name: &str) -> String {
    let n: String = name
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c == ' ' || c == '_' { '-' } else { c })
        .collect();
    n.strip_suffix(".git").unwrap_or(&n).to_string()
}

impl PhiScope {
    pub fn new(repos: Vec<String>) -> Self {
        Self {
            repos: repos.iter().map(|r| norm(r)).collect(),
            known: HashSet::new(),
            phi: HashSet::new(),
        }
    }

    /// Is this one name (a path component or a project name) a PHI repo, or a
    /// worktree or checkout named after one (`admin-portal-feat-x`)?
    fn name_is_phi(&self, name: &str) -> bool {
        let n = norm(name);
        self.repos
            .iter()
            .any(|r| n == *r || n.starts_with(&format!("{r}-")) || n.starts_with(&format!("{r}.")))
    }

    /// Any component of the path names a PHI repo: a worktree inside the repo,
    /// or a checkout beside it, is PHI too.
    fn path_is_phi(&self, path: &str) -> bool {
        path.split(['/', '\\'])
            .filter(|c| !c.is_empty())
            .any(|c| self.name_is_phi(c))
    }

    /// What is matched, plainly: a focus is PHI when its project path has a
    /// component naming a PHI repo (or a checkout or worktree named after
    /// one), its project name does, or its path is a git worktree whose
    /// `.git` file points into a PHI repo's `.git/worktrees/`. A checkout that
    /// is a PHI repo under another name, with no such pointer, is NOT matched:
    /// list it in `phi_repos` by that name.
    fn focus_is_phi(&self, meta: &crate::ipc::protocol::FocusMeta) -> bool {
        meta.project_path.as_deref().is_some_and(|p| {
            self.path_is_phi(p) || gitdir_of(p).is_some_and(|g| self.path_is_phi(&g))
        }) || meta
            .project_name
            .as_deref()
            .is_some_and(|n| self.name_is_phi(n))
    }

    /// Replace what is known with the registry's focuses.
    pub fn refresh(&mut self, focuses: &[crate::ipc::protocol::FocusMeta]) {
        self.known = focuses.iter().map(|f| f.tag.clone()).collect();
        self.phi = focuses
            .iter()
            .filter(|f| self.focus_is_phi(f))
            .map(|f| f.tag.clone())
            .collect();
    }

    /// Learn from a focus frame passing through.
    pub fn observe(&mut self, msg: &ServerMsg) {
        match msg {
            ServerMsg::FocusListResp { focuses, .. }
            | ServerMsg::FocusRegistryUpdated { focuses, .. } => self.refresh(focuses),
            ServerMsg::FocusCreated { meta, .. } => {
                self.known.insert(meta.tag.clone());
                if self.focus_is_phi(meta) {
                    self.phi.insert(meta.tag.clone());
                }
            }
            _ => {}
        }
    }

    /// May a frame or read about this tag leave? Only a tag the registry
    /// holds, and which is not PHI-scoped.
    pub fn is_known(&self, tag: &str) -> bool {
        self.known.contains(tag)
    }

    pub fn tag_is_shareable(&self, tag: &str) -> bool {
        self.known.contains(tag) && !self.phi.contains(tag)
    }

    /// A Mother job is PHI by its repo, its plan path, its pull-request URL
    /// (host and path components), or the focus that queued it (its tag, or
    /// its name). A job queued from a focus the registry does not hold cannot
    /// be classified, so it is withheld too.
    fn job_is_phi(&self, job: &crate::mother::MotherJob) -> bool {
        let origin_phi = job.origin.as_ref().is_some_and(|o| {
            o.focus
                .as_deref()
                .is_some_and(|t| !self.known.contains(t) || self.phi.contains(t))
                || o.focus_name.as_deref().is_some_and(|n| self.name_is_phi(n))
        });
        self.path_is_phi(&job.repo)
            || job
                .plan_path
                .as_deref()
                .is_some_and(|p| self.path_is_phi(p))
            || job.pr_url.as_deref().is_some_and(|u| self.path_is_phi(u))
            || origin_phi
    }

    /// Is this focus PHI, by its tag in the registry or by its own fields?
    fn meta_is_phi(&self, meta: &crate::ipc::protocol::FocusMeta) -> bool {
        self.phi.contains(&meta.tag) || self.focus_is_phi(meta)
    }

    /// `msg` without its PHI-scoped or unclassifiable content; `None` when
    /// nothing is left. A `personal` satellite's PHI work is never sent at all
    /// (the primary only accepts a `personal` frame the network filter leaves
    /// unchanged, so a metadata-only version could not be delivered).
    pub fn strip(&self, msg: ServerMsg) -> Option<ServerMsg> {
        match msg {
            ServerMsg::MotherJobs { jobs, host } => Some(ServerMsg::MotherJobs {
                jobs: jobs.into_iter().filter(|j| !self.job_is_phi(j)).collect(),
                host,
            }),
            ServerMsg::FocusListResp { focuses, host } => Some(ServerMsg::FocusListResp {
                focuses: focuses
                    .into_iter()
                    .filter(|f| !self.meta_is_phi(f))
                    .collect(),
                host,
            }),
            ServerMsg::FocusRegistryUpdated { focuses, host } => {
                Some(ServerMsg::FocusRegistryUpdated {
                    focuses: focuses
                        .into_iter()
                        .filter(|f| !self.meta_is_phi(f))
                        .collect(),
                    host,
                })
            }
            ServerMsg::FocusCreated { meta, host } => {
                (!self.meta_is_phi(&meta)).then_some(ServerMsg::FocusCreated { meta, host })
            }
            ServerMsg::SessionListResp { sessions, host } => Some(ServerMsg::SessionListResp {
                sessions: sessions
                    .into_iter()
                    .filter(|s| self.tag_is_shareable(&s.tag))
                    .collect(),
                host,
            }),
            other => {
                match server_msg_tag(&other) {
                    MsgTag::Tag(tag) if !self.tag_is_shareable(tag) => return None,
                    // A focus-scoped frame with no tag cannot be classified.
                    MsgTag::Missing => return None,
                    MsgTag::Tag(_) | MsgTag::Untagged => {}
                }
                // A working directory in the frame must itself be outside the
                // PHI scope, whatever tag the frame claims.
                let cwd = match &other {
                    ServerMsg::Activity(e) => e.cwd.as_deref(),
                    ServerMsg::TerminalState { terminal } => terminal.cwd.as_deref(),
                    _ => None,
                };
                if cwd.is_some_and(|c| {
                    self.path_is_phi(c) || gitdir_of(c).is_some_and(|g| self.path_is_phi(&g))
                }) {
                    return None;
                }
                Some(other)
            }
        }
    }
}

/// The `gitdir:` a git worktree's `.git` file points at, if `dir` is one.
fn gitdir_of(dir: &str) -> Option<String> {
    let meta = std::fs::metadata(Path::new(dir).join(".git")).ok()?;
    if !meta.is_file() || meta.len() > 4096 {
        return None;
    }
    let text = std::fs::read_to_string(Path::new(dir).join(".git")).ok()?;
    text.lines()
        .find_map(|l| l.strip_prefix("gitdir:"))
        .map(|g| g.trim().to_string())
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
        self.shape(msg)
    }

    /// [`Self::publish`] without learning from the frame: for a retained frame
    /// replayed later, which must be judged against the registry as it is now
    /// and must not overwrite it with what it said then.
    pub fn republish(&self, msg: ServerMsg) -> Option<ServerMsg> {
        self.shape(msg)
    }

    fn shape(&self, msg: ServerMsg) -> Option<ServerMsg> {
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

    /// Re-read the daemon's focus registry (the authority on which tag is
    /// which repo's).
    pub fn refresh_registry(&mut self, focuses: &[crate::ipc::protocol::FocusMeta]) {
        self.phi.refresh(focuses);
    }

    /// May a routed request name this tag? A PHI-scoped or unknown focus is
    /// refused.
    pub fn request_allowed(&self, msg: &ClientMsg) -> bool {
        let tag = match msg {
            ClientMsg::SessionModelGet { tag, .. }
            | ClientMsg::ActivitySnapshotRequest { tag, .. }
            | ClientMsg::SessionAttach { tag, .. }
            | ClientMsg::SessionDetach { tag, .. } => Some(tag.as_str()),
            _ => None,
        };
        tag.is_none_or(|t| self.phi.tag_is_shareable(t))
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
/// the uplink does not publish. A key file at any other mode, or that is not
/// 32 bytes, is refused (it is never regenerated: this process did not create
/// it, and replacing it would silently change every pseudonymous tag).
pub fn load_or_create_tag_key(path: &Path) -> std::io::Result<[u8; 32]> {
    use std::io::Write;
    if path.exists() {
        return read_tag_key(path);
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut key = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut key);
    // Written whole under a temporary name, then linked into place, so the key
    // file is never visible empty or partial, and never replaces another.
    let mut tmp_name = path.as_os_str().to_owned();
    tmp_name.push(format!(".tmp{}", std::process::id()));
    let tmp = std::path::PathBuf::from(tmp_name);
    let _ = std::fs::remove_file(&tmp);
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut f = opts.open(&tmp)?;
    let written = f.write_all(&key).and_then(|_| f.sync_all());
    drop(f);
    let linked = written.and_then(|_| std::fs::hard_link(&tmp, path));
    let _ = std::fs::remove_file(&tmp);
    match linked {
        Ok(()) => Ok(key),
        // Another start created it first.
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => read_tag_key(path),
        Err(e) => Err(e),
    }
}

fn read_tag_key(path: &Path) -> std::io::Result<[u8; 32]> {
    require_private(path, "uplink tag key")?;
    let bytes = std::fs::read(path)?;
    <[u8; 32]>::try_from(bytes.as_slice()).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "the uplink tag key {} is not 32 bytes ({}); remove it by hand to make a new one",
                path.display(),
                bytes.len()
            ),
        )
    })
}

/// Refuse a secret file that is not exactly mode 0600.
fn require_private(path: &Path, what: &str) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(path)?.permissions().mode() & 0o777;
        if mode != 0o600 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!(
                    "the {what} {} has mode {mode:o}, not 600; run `chmod 600 {}`",
                    path.display(),
                    path.display()
                ),
            ));
        }
    }
    #[cfg(not(unix))]
    let _ = (path, what);
    Ok(())
}

// ── the device-admin relay ────────────────────────────────────────────────────

type LocalTx = mpsc::UnboundedSender<ServerMsg>;

struct RelayedRequest {
    conn_key: String,
    original_id: String,
    tx: LocalTx,
    /// For a relayed `DevicePairCancel`: the pairing it cancels. The primary
    /// answers a cancel with the pairing's outcome, not under the request id.
    cancel_of: Option<String>,
}

#[derive(Default)]
struct RelayState {
    up: Option<mpsc::Sender<UplinkFrame>>,
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
        let cancel_of = match &msg {
            ClientMsg::DevicePairCancel { pairing_id, .. } => Some(pairing_id.clone()),
            _ => None,
        };
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
                    cancel_of,
                },
            );
        }
        if up.try_send(UplinkFrame::Client { msg }).is_err() {
            // Down, or its queue is full: either way the verb did not leave.
            let sent = format!("s{}", st.next_request);
            st.requests.remove(&sent);
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
                let _ = up.try_send(UplinkFrame::Client {
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
    pub fn set_up(&self, up: Option<mpsc::Sender<UplinkFrame>>) {
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
                // The pairing ended, so a cancel aimed at it is answered.
                st.requests
                    .retain(|_, r| r.cancel_of.as_deref() != Some(pairing_id.as_str()));
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
    /// The retained frames as broadcast (unfiltered), by [`cache_key`].
    cache: BTreeMap<String, ServerMsg>,
    publish: Option<mpsc::Sender<UplinkFrame>>,
}

impl Shared {
    /// Forget retained frames about a tag the registry no longer holds.
    fn evict_dead_tags(&mut self) {
        let phi = self.forwarder.phi();
        self.cache.retain(|_, raw| match server_msg_tag(raw) {
            MsgTag::Tag(t) => phi.is_known(t),
            MsgTag::Untagged | MsgTag::Missing => true,
        });
    }

    /// The frames to send on a fresh connection: every retained frame, judged
    /// again now. One that is no longer shareable (its focus became sensitive
    /// or PHI while the uplink was down) is dropped from the cache too.
    fn replay(&mut self) -> Vec<ServerMsg> {
        self.evict_dead_tags();
        let forwarder = &self.forwarder;
        let mut out = Vec::new();
        self.cache
            .retain(|_, raw| match forwarder.republish(raw.clone()) {
                Some(m) => {
                    out.push(m);
                    true
                }
                None => false,
            });
        out
    }
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
    tokio::spawn(filter_task(
        env.tx.subscribe(),
        Arc::clone(&shared),
        env.dispatch.clone(),
    ));
    tokio::spawn(connection_loop(env, shared));
}

async fn filter_task(
    mut rx: broadcast::Receiver<ServerMsg>,
    shared: Arc<Mutex<Shared>>,
    dispatch: LocalDispatch,
) {
    loop {
        match rx.recv().await {
            Ok(msg) => {
                let key = cache_key(&msg);
                // Which tag is which repo's: read from the registry, not guessed
                // from the frames seen so far. (Never while holding `shared`.)
                let registry = dispatch.focus_registry();
                let mut sh = shared.lock().unwrap();
                sh.forwarder.refresh_registry(&registry);
                // The replay keeps the frame as it was broadcast, not as it was
                // filtered: it is judged again when it is replayed, against the
                // registry and the sensitive tags of that moment.
                let raw = key.is_some().then(|| msg.clone());
                let out = sh.forwarder.publish(msg);
                sh.evict_dead_tags();
                if let (Some(k), Some(raw)) = (key, raw) {
                    if out.is_some() && (sh.cache.len() < MAX_CACHED || sh.cache.contains_key(&k)) {
                        sh.cache.insert(k, raw);
                    } else if out.is_none() {
                        // Kept home now: it must not linger in the replay.
                        sh.cache.remove(&k);
                    }
                }
                if let (Some(out), Some(p)) = (out, &sh.publish) {
                    if p.try_send(UplinkFrame::Publish { msg: out }).is_err() {
                        note_dropped("a published frame (the uplink's queue is full)");
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
    /// The connection was admitted and then ended, after this long.
    Ended { up_for: Duration },
    /// It never got going.
    Failed(String),
}

async fn connection_loop(env: Env, shared: Arc<Mutex<Shared>>) {
    reconnect_loop(|| run_session(&env, &shared)).await;
}

/// Run sessions forever, waiting between them. The wait grows after every
/// session that did not stay up for [`STABLE_AFTER`], admitted or not: a
/// primary that welcomes this satellite and then closes it (a revoked token,
/// two satellites sharing one) would otherwise be redialled, and the replay
/// resent, every second.
async fn reconnect_loop<F, Fut>(mut run: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = SessionEnd>,
{
    let mut backoff = BACKOFF_START;
    loop {
        let wait = match run().await {
            SessionEnd::NoUplink => {
                warn!("the primary does not advertise uplink support; trying again in 10 minutes");
                NO_UPLINK_RETRY
            }
            SessionEnd::Ended { up_for } if up_for >= STABLE_AFTER => {
                info!("uplink to the primary closed; reconnecting");
                backoff = BACKOFF_START;
                backoff
            }
            SessionEnd::Ended { up_for } => {
                warn!("uplink closed after {up_for:?}; retrying in {backoff:?}");
                let w = backoff;
                backoff = next_backoff(backoff);
                w
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
    require_private(path, "uplink token").map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            format!("cannot read the token at {}: {e}", path.display())
        } else {
            e.to_string()
        }
    })?;
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

    let (out_tx, mut out_rx) = mpsc::channel::<UplinkFrame>(OUT_QUEUE);
    let (pub_tx, mut pub_rx) = mpsc::channel::<UplinkFrame>(PUBLISH_QUEUE);
    {
        // Replay what is retained, then go live, atomically.
        // The registry is read before the lock, as everywhere else.
        let registry = env.dispatch.focus_registry();
        let mut sh = shared.lock().unwrap();
        sh.forwarder.refresh_registry(&registry);
        for msg in sh.replay() {
            let _ = pub_tx.try_send(UplinkFrame::Publish { msg });
        }
        sh.publish = Some(pub_tx.clone());
    }
    env.relay.set_up(Some(out_tx.clone()));
    let admitted_at = tokio::time::Instant::now();
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
    if let Err(e) = reason {
        debug!("uplink ended: {e}");
    }
    SessionEnd::Ended {
        up_for: admitted_at.elapsed(),
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
    out: &mpsc::Sender<UplinkFrame>,
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
    // A bounded id, and a bounded number of open reads. A refusal is answered
    // under the id (a primary that sent a hostile id is not told it back if it
    // is too long to be an id of ours).
    if id.is_empty() || id.len() > MAX_ROUTED_ID {
        note_dropped("a routed request with an unusable id");
        return;
    }
    if routed.live.len() >= MAX_ROUTED && !routed.live.contains_key(&id) {
        let _ = out.try_send(UplinkFrame::Reply {
            id,
            msg: withheld_msg(),
        });
        return;
    }
    let key = format!("uplink:{id}");
    if matches!(msg, ClientMsg::SessionDetach { .. }) {
        env.dispatch
            .run_routed(msg, &key, &mpsc::unbounded_channel().0);
        routed.close(&env.dispatch, &id);
        return;
    }
    let refused = {
        let registry = env.dispatch.focus_registry();
        let mut sh = shared.lock().unwrap();
        sh.forwarder.refresh_registry(&registry);
        !sh.forwarder.request_allowed(&msg)
    };
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
                tokio::time::timeout(left, rx.recv())
                    .await
                    .unwrap_or_default()
            };
            let Some(m) = next else { break };
            let is_refusal = matches!(m, ServerMsg::Error { .. } | ServerMsg::Withheld { .. });
            let registry = dispatch.focus_registry();
            let filtered = {
                let mut sh = shared.lock().unwrap();
                sh.forwarder.refresh_registry(&registry);
                sh.forwarder.reply(m)
            };
            if let Some(m) = filtered {
                if out
                    .try_send(UplinkFrame::Reply {
                        id: reply_id.clone(),
                        msg: m,
                    })
                    .is_err()
                {
                    note_dropped("a routed reply (the uplink's queue is full)");
                }
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
        mpsc::Receiver<UplinkFrame>,
        LocalTx,
        mpsc::UnboundedReceiver<ServerMsg>,
    ) {
        let relay = UplinkRelay::new(local);
        let (up_tx, up_rx) = mpsc::channel(64);
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
        personal.refresh_registry(&[
            focus("cody-a", "/code/admin-portal"),
            focus("cody-b", "/code/blog"),
        ]);
        assert!(!personal.request_allowed(&ClientMsg::SessionAttach {
            tag: "cody-a".into(),
            host: None
        }));
        assert!(personal.request_allowed(&ClientMsg::SessionAttach {
            tag: "cody-b".into(),
            host: None
        }));
        assert!(
            !personal.request_allowed(&ClientMsg::SessionAttach {
                tag: "cody-unknown".into(),
                host: None
            }),
            "an unknown tag is refused"
        );
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

    #[test]
    fn redact_for_network_is_idempotent_so_a_reply_survives_the_primarys_check() {
        let tags = SensitiveTags::default();
        let samples = vec![
            jobs_msg(vec![job("0123456789abcdef", "/code/blog")]),
            ServerMsg::SessionListResp {
                sessions: vec![],
                host: Some("kobe".into()),
            },
            ServerMsg::FocusListResp {
                focuses: vec![focus("cody-a", "/code/blog")],
                host: Some("kobe".into()),
            },
            ServerMsg::ApprovalPending {
                tag: "cody-a".into(),
                count: 3,
                host: None,
            },
        ];
        for m in samples {
            let once = crate::ipc::peer::redact_for_network(m, &tags);
            let twice = crate::ipc::peer::redact_for_network(once.clone(), &tags);
            assert_eq!(
                serde_json::to_value(&once).unwrap(),
                serde_json::to_value(&twice).unwrap()
            );
        }
    }

    #[test]
    fn a_routed_read_is_a_network_peer_so_it_never_closes_a_merge_gate() {
        // `SessionAttach` attaches a network peer through `attach_network`.
        assert!(PeerTrust::Routed.is_network());
    }

    #[test]
    fn a_satellite_binds_loopback_only() {
        let lan: std::net::SocketAddr = "0.0.0.0:47100".parse().unwrap();
        assert_eq!(
            crate::config::loopback_only(lan).to_string(),
            "127.0.0.1:47100"
        );
        let lo: std::net::SocketAddr = "127.0.0.1:47101".parse().unwrap();
        assert_eq!(crate::config::loopback_only(lo), lo);
    }

    // ── fix round 1 ──────────────────────────────────────────────────────────

    fn activity(tag: Option<&str>, cwd: Option<&str>) -> ServerMsg {
        let mut v = serde_json::json!({
            "type": "activity", "ts": "2026-01-01T00:00:00Z", "agent": "cody",
            "kind": "tool_use", "summary": "MARKER-summary", "tool_name": "MARKER-tool",
        });
        if let Some(t) = tag {
            v["focus_tag"] = t.into();
        }
        if let Some(c) = cwd {
            v["cwd"] = c.into();
        }
        serde_json::from_value(v).unwrap()
    }

    fn registry_forwarder(egress: Egress) -> Forwarder {
        let mut f = forwarder(egress);
        f.refresh_registry(&[
            focus("cody-a", "/code/admin-portal"),
            focus("cody-b", "/code/blog"),
        ]);
        f
    }

    #[test]
    fn a_personal_satellites_activity_frames_are_judged_by_their_focus_tag_and_cwd() {
        let mut f = registry_forwarder(Egress::Personal);
        assert!(
            f.publish(activity(Some("cody-a"), Some("/code/admin-portal/app")))
                .is_none(),
            "a PHI focus's activity stays home"
        );
        assert!(
            f.publish(activity(Some("ghost"), None)).is_none(),
            "a tag the registry does not hold is not shared"
        );
        assert!(
            f.publish(activity(None, None)).is_none(),
            "an unattributed activity cannot be classified"
        );
        assert!(
            f.publish(activity(Some("cody-b"), Some("/code/admin-portal/app")))
                .is_none(),
            "a cwd inside a PHI repo keeps the frame home whatever tag it claims"
        );
        let out = f
            .publish(activity(Some("cody-b"), Some("/code/blog")))
            .expect("an ordinary focus's activity is published");
        assert_eq!(server_msg_host(&out), Some(Some("kobe")));
    }

    #[test]
    fn every_frame_variant_the_forwarder_can_see_yields_a_tag_or_is_untagged() {
        let tagged = |v: serde_json::Value| -> ServerMsg { serde_json::from_value(v).unwrap() };
        let cases: Vec<(ServerMsg, MsgTag<'_>)> = vec![
            (activity(Some("t1"), None), MsgTag::Tag("t1")),
            (activity(None, None), MsgTag::Missing),
            (
                tagged(serde_json::json!({"type":"approval_pending","tag":"t2","count":1})),
                MsgTag::Tag("t2"),
            ),
            (
                tagged(serde_json::json!({"type":"session_bridge","tag":"t3","connected":true})),
                MsgTag::Tag("t3"),
            ),
            (jobs_msg(vec![]), MsgTag::Untagged),
            (ServerMsg::Pong, MsgTag::Untagged),
            (
                ServerMsg::Error {
                    message: "x".into(),
                },
                MsgTag::Untagged,
            ),
            (
                tagged(serde_json::json!({"type":"focus_registry_updated","focuses":[]})),
                MsgTag::Untagged,
            ),
        ];
        for (msg, want) in &cases {
            assert_eq!(&server_msg_tag(msg), want, "{msg:?}");
        }
    }

    fn shared_for(egress: Egress, tags: &SensitiveTags) -> Shared {
        let forwarder = Forwarder::new(
            "kobe".into(),
            egress,
            key(),
            tags.clone(),
            vec!["admin-portal".into()],
            None,
        );
        Shared {
            forwarder,
            cache: BTreeMap::new(),
            publish: None,
        }
    }

    /// What `filter_task` does with one broadcast.
    fn broadcast_one(sh: &mut Shared, msg: ServerMsg) -> Option<ServerMsg> {
        let key = cache_key(&msg);
        let raw = msg.clone();
        let out = sh.forwarder.publish(msg);
        if let (Some(k), true) = (key, out.is_some()) {
            sh.cache.insert(k, raw);
        }
        out
    }

    fn pending(tag: &str) -> ServerMsg {
        ServerMsg::ApprovalPending {
            tag: tag.into(),
            count: 1,
            host: None,
        }
    }

    #[test]
    fn a_focus_that_became_sensitive_while_the_uplink_was_down_is_not_replayed() {
        let tags = SensitiveTags::default();
        let mut sh = shared_for(Egress::Work, &tags);
        sh.forwarder
            .refresh_registry(&[focus("cody-x", "/code/blog")]);
        assert!(broadcast_one(&mut sh, pending("cody-x")).is_some());
        assert_eq!(sh.cache.len(), 1);
        assert_eq!(sh.replay().len(), 1, "still shareable: replayed");
        tags.mark_tag("cody-x");
        let replayed = sh.replay();
        assert!(
            replayed.is_empty(),
            "a now-sensitive focus must not replay: {replayed:?}"
        );
        assert!(sh.cache.is_empty(), "and is forgotten");
    }

    #[test]
    fn a_focus_that_became_phi_while_the_uplink_was_down_is_not_replayed() {
        let tags = SensitiveTags::default();
        let mut sh = shared_for(Egress::Personal, &tags);
        sh.forwarder
            .refresh_registry(&[focus("cody-a", "/code/blog")]);
        // A registry frame (stale by replay time) and a count are retained.
        let reg = ServerMsg::FocusRegistryUpdated {
            focuses: vec![focus("cody-a", "/code/blog")],
            host: None,
        };
        assert!(broadcast_one(&mut sh, reg).is_some());
        assert!(broadcast_one(&mut sh, pending("cody-a")).is_some());
        assert_eq!(sh.cache.len(), 2);
        // The registry now says cody-a is in a PHI repo.
        sh.forwarder
            .refresh_registry(&[focus("cody-a", "/code/admin-portal")]);
        let replayed = sh.replay();
        let json = serde_json::to_string(&replayed).unwrap();
        assert!(!json.contains("cody-a"), "{json}");
        assert!(
            sh.forwarder.publish(pending("cody-a")).is_none(),
            "replaying the stale registry frame did not undo what is known"
        );
    }

    #[test]
    fn a_retained_frame_for_a_tag_the_registry_dropped_is_evicted() {
        let tags = SensitiveTags::default();
        let mut sh = shared_for(Egress::Personal, &tags);
        sh.forwarder
            .refresh_registry(&[focus("cody-b", "/code/blog")]);
        assert!(broadcast_one(&mut sh, pending("cody-b")).is_some());
        sh.forwarder.refresh_registry(&[]);
        // Evicted as the registry changes, not only when a reconnect replays.
        sh.evict_dead_tags();
        assert!(sh.cache.is_empty());
        assert!(sh.replay().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn the_reconnect_loop_backs_off_after_sessions_that_close_straight_after_welcome() {
        let starts = Arc::new(Mutex::new(Vec::<tokio::time::Instant>::new()));
        let seen = Arc::clone(&starts);
        let task = tokio::spawn(reconnect_loop(move || {
            seen.lock().unwrap().push(tokio::time::Instant::now());
            async {
                SessionEnd::Ended {
                    up_for: Duration::ZERO,
                }
            }
        }));
        tokio::time::sleep(Duration::from_secs(20)).await;
        task.abort();
        let starts = starts.lock().unwrap();
        // Waits of 1, 2, 4, 8 s: attempts at 0, 1, 3, 7 and 15 s.
        assert_eq!(starts.len(), 5, "{starts:?}");
        let gaps: Vec<u64> = starts.windows(2).map(|w| (w[1] - w[0]).as_secs()).collect();
        assert_eq!(gaps, [1, 2, 4, 8]);
    }

    #[tokio::test(start_paused = true)]
    async fn the_reconnect_loop_resets_only_after_a_session_that_stayed_up() {
        let starts = Arc::new(Mutex::new(Vec::<tokio::time::Instant>::new()));
        let seen = Arc::clone(&starts);
        let script = Arc::new(Mutex::new(VecDeque::from(vec![
            SessionEnd::Failed("x".into()),
            SessionEnd::Failed("x".into()),
            SessionEnd::Ended {
                up_for: STABLE_AFTER,
            },
            SessionEnd::Ended {
                up_for: Duration::ZERO,
            },
            SessionEnd::Ended {
                up_for: Duration::ZERO,
            },
        ])));
        let task = tokio::spawn(reconnect_loop(move || {
            seen.lock().unwrap().push(tokio::time::Instant::now());
            let next = script.lock().unwrap().pop_front();
            async move { next.unwrap_or(SessionEnd::NoUplink) }
        }));
        tokio::time::sleep(Duration::from_secs(10)).await;
        task.abort();
        let starts = starts.lock().unwrap();
        let gaps: Vec<u64> = starts.windows(2).map(|w| (w[1] - w[0]).as_secs()).collect();
        // 1 and 2 (failures), then 1 (reset by the long session), 1, 2.
        assert_eq!(gaps, [1, 2, 1, 1, 2]);
    }

    #[cfg(unix)]
    fn set_mode(path: &Path, mode: u32) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_tag_key_that_is_not_mode_0600_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tag-key");
        std::fs::write(&path, [9u8; 32]).unwrap();
        set_mode(&path, 0o644);
        let err = load_or_create_tag_key(&path).expect_err("a world-readable key is refused");
        assert!(err.to_string().contains("tag-key"), "{err}");
        set_mode(&path, 0o600);
        assert_eq!(load_or_create_tag_key(&path).unwrap(), [9u8; 32]);
    }

    #[test]
    fn an_empty_or_short_tag_key_is_refused_and_left_alone_never_regenerated() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tag-key");
        for content in [&b""[..], &b"short"[..]] {
            std::fs::write(&path, content).unwrap();
            #[cfg(unix)]
            set_mode(&path, 0o600);
            let err = load_or_create_tag_key(&path).expect_err("not a key");
            assert!(err.to_string().contains("tag-key"), "{err}");
            assert_eq!(std::fs::read(&path).unwrap(), content);
        }
    }

    #[test]
    fn creating_the_tag_key_leaves_no_temporary_file_behind() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tag-key");
        load_or_create_tag_key(&path).unwrap();
        let names: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
            .collect();
        assert_eq!(names, ["tag-key"]);
        assert_eq!(std::fs::read(&path).unwrap().len(), 32);
    }

    #[cfg(unix)]
    #[test]
    fn a_token_file_that_is_not_mode_0600_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("uplink-token");
        std::fs::write(&path, "tok\n").unwrap();
        set_mode(&path, 0o644);
        let err = read_token(&path).expect_err("a world-readable token is refused");
        assert!(err.contains("uplink-token"), "{err}");
        set_mode(&path, 0o600);
        assert_eq!(read_token(&path).unwrap(), "tok");
    }

    #[test]
    fn a_job_is_phi_by_its_plan_path_pr_url_or_origin_not_only_its_repo() {
        let mut f = forwarder(Egress::Personal);
        f.refresh_registry(&[
            focus("cody-a", "/code/admin-portal"),
            focus("cody-b", "/code/blog"),
        ]);
        let with = |id: &str, extra: serde_json::Value| {
            let mut j = job(id, "/code/blog");
            j["plan_path"] = "/code/blog/plan.md".into();
            for (k, v) in extra.as_object().unwrap() {
                j[k] = v.clone();
            }
            j
        };
        let out = f
            .publish(jobs_msg(vec![
                with(
                    "plan0000",
                    serde_json::json!({"plan_path": "/code/admin-portal-feat/plan.md"}),
                ),
                with(
                    "pr000000",
                    serde_json::json!({"pr_url": "https://github.com/o/referral-monitor/pull/3"}),
                ),
                with(
                    "orig-phi0",
                    serde_json::json!({"origin": {"focus": "cody-a"}}),
                ),
                with(
                    "orig-unk0",
                    serde_json::json!({"origin": {"focus": "ghost"}}),
                ),
                with(
                    "orig-name",
                    serde_json::json!({"origin": {"focus_name": "admin-portal"}}),
                ),
                with(
                    "okok0000",
                    serde_json::json!({"origin": {"focus": "cody-b"}}),
                ),
            ]))
            .unwrap();
        match out {
            ServerMsg::MotherJobs { jobs, .. } => assert_eq!(
                jobs.iter().map(|j| j.id.as_str()).collect::<Vec<_>>(),
                ["okok0000"]
            ),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_worktree_whose_git_file_points_into_a_phi_repo_is_phi() {
        let dir = tempfile::tempdir().unwrap();
        let wt = dir.path().join("scratch-checkout");
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(
            wt.join(".git"),
            "gitdir: /code/admin-portal/.git/worktrees/scratch-checkout\n",
        )
        .unwrap();
        let mut f = forwarder(Egress::Personal);
        f.refresh_registry(&[focus("cody-w", wt.to_str().unwrap())]);
        assert!(f.publish(pending("cody-w")).is_none());
        // The same shape pointing elsewhere is not PHI.
        std::fs::write(wt.join(".git"), "gitdir: /code/blog/.git/worktrees/x\n").unwrap();
        f.refresh_registry(&[focus("cody-w", wt.to_str().unwrap())]);
        assert!(f.publish(pending("cody-w")).is_some());
    }

    #[test]
    fn a_cancel_request_is_forgotten_once_its_pairing_has_ended() {
        let (relay, mut up, tx, _rx) = relay_pair(SatelliteAdmin::Full);
        level(&relay, SatelliteAdmin::Full);
        relay.relay_verb(
            ClientMsg::DevicePairCancel {
                request_id: "c".into(),
                pairing_id: "p9".into(),
                origin: None,
            },
            "conn-1",
            &tx,
        );
        assert!(up.try_recv().is_ok());
        assert_eq!(relay.state.lock().unwrap().requests.len(), 1);
        relay.from_primary(ServerMsg::DevicePairOutcome {
            pairing_id: "p9".into(),
            outcome: crate::ipc::devices::PairOutcomeKind::Cancelled,
            name: None,
            kind: None,
            replaced: false,
        });
        assert!(relay.state.lock().unwrap().requests.is_empty());
    }

    #[test]
    fn a_full_uplink_queue_refuses_a_verb_instead_of_growing() {
        let relay = UplinkRelay::new(SatelliteAdmin::Full);
        let (up_tx, _up_rx) = mpsc::channel(1);
        relay.set_up(Some(up_tx));
        level(&relay, SatelliteAdmin::Full);
        let (tx, mut rx) = mpsc::unbounded_channel();
        let list = || ClientMsg::DeviceList {
            request_id: "l".into(),
        };
        relay.relay_verb(list(), "c", &tx);
        relay.relay_verb(list(), "c", &tx);
        match rx.try_recv() {
            Ok(ServerMsg::DeviceAdminError { reason, .. }) => {
                assert_eq!(reason, SERVER_UNREACHABLE)
            }
            other => panic!("{other:?}"),
        }
    }
}
