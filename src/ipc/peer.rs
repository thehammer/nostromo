//! Who is on the other end of an IPC connection, and what they may see.
//!
//! `nostromd` serves the Mac app over a Unix socket and iOS/LAN clients over an
//! **unauthenticated** TCP listener. The server tags every connection with its
//! [`Transport`] and derives a [`PeerTrust`]. Teri/Fred data (mail subjects and
//! senders, todos, work items) is *sensitive*: a network peer must not be able
//! to read it, nor to make the daemon act on it.
//!
//! The model is **allow-list shaped for anything that can carry or act on
//! Teri/Fred-derived data**: it is not enough to block the dedicated frames,
//! because the same text also travels in session transcripts, pane content,
//! notifications, decisions, activity, focus metadata and Mother jobs. Those
//! frames are scoped by a focus tag (or Mother job id), and a network peer only
//! receives/drives them for tags that are not *sensitive* — see
//! [`SensitiveTags`].
//!
//! The classification functions below are deliberately exhaustive `match`es
//! with no wildcard arm: adding a `ServerMsg` or `ClientMsg` variant breaks
//! this module's build until the author decides how a network peer is treated.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

use serde::{Deserialize, Serialize};
use tracing::warn;

use super::protocol::{ClientMsg, FocusMeta, ServerMsg, Topic};
use crate::data::work::WorkResult;

/// Wire transport a connection arrived on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    Unix,
    Tcp,
}

/// How far a peer is trusted.
///
/// `OperatorApp` is reserved for a verified Nostromo Mac app (terminal-pane
/// 1a adds the bundle verifier); nothing here assigns it yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerTrust {
    /// A Unix-socket peer verified to be the Nostromo app. Not yet assigned.
    OperatorApp,
    /// Any other local (Unix-socket) peer.
    LocalOther,
    /// A TCP peer: unauthenticated, possibly anywhere on the LAN.
    Tcp,
}

impl PeerTrust {
    pub fn from_transport(transport: Transport) -> Self {
        match transport {
            Transport::Unix => PeerTrust::LocalOther,
            Transport::Tcp => PeerTrust::Tcp,
        }
    }

    /// True for peers reached over the network.
    pub fn is_network(&self) -> bool {
        match self {
            PeerTrust::Tcp => true,
            PeerTrust::OperatorApp | PeerTrust::LocalOther => false,
        }
    }
}

// ── sensitive tags ────────────────────────────────────────────────────────────

/// Is `name` one of the agents whose sessions hold mail/calendar/todo tools?
/// Case-insensitive, ignores surrounding whitespace, and looks through a
/// plugin qualifier (`teri:teri` is the same agent as `teri`).
pub fn is_teri_or_fred_agent(name: &str) -> bool {
    let bare = name.trim().rsplit(':').next().unwrap_or("").trim();
    bare.eq_ignore_ascii_case("fred") || bare.eq_ignore_ascii_case("teri")
}

#[derive(Default, Serialize, Deserialize)]
struct Registered {
    /// Each registered tag with the random opaque id shown to network peers in
    /// its place. Random rather than derived from the tag, so the id of a
    /// short slug (a Jira key) cannot be recomputed from a guess.
    #[serde(default)]
    tags: BTreeMap<String, String>,
    #[serde(default)]
    jobs: BTreeSet<String>,
    /// Set (in memory only) when the persisted registry exists but cannot be
    /// read: the daemon can no longer tell which tags are work-derived, so it
    /// fails closed and treats every tag and job as sensitive.
    #[serde(skip)]
    unreadable: bool,
    /// Opaque ids minted in memory for sensitive tags that are not registered
    /// (a tag that merely *looks* like a Fred/Teri agent, or any tag while the
    /// registry is unreadable). Never persisted.
    #[serde(skip)]
    ephemeral: BTreeMap<String, String>,
    /// Bytes held by `ephemeral` (keys plus values), kept so the cap is on
    /// memory, not on entry count.
    #[serde(skip)]
    ephemeral_bytes: usize,
    /// The last write of the registry failed, so what is on disk may lack
    /// recent registrations. Cleared by the next successful write.
    #[serde(skip)]
    degraded: bool,
    /// The registry on disk is known to have lost registrations (a previous
    /// run could not write it, or the disk cannot be written now): which tags
    /// are missing is unknowable, so every resumed session is treated as
    /// sensitive until [`SensitiveTags::settle_lost_history`].
    #[serde(skip)]
    lost_history: bool,
    /// Tags whose session a network peer has written to. In memory only.
    #[serde(skip)]
    network_driven: BTreeSet<String>,
}

/// Which focus tags and Mother jobs carry Teri/Fred-derived content.
///
/// A tag is sensitive when it is a built-in (`fred`, `teri`), when a session
/// of the `fred`/`teri` agent runs under it, or when it was **registered**
/// because the focus was created from work items (`WorkSend`) or seeded with
/// context by an agent (`nostromo.create_focus` with `initial_context`) — the
/// seeded text can be a mail body or a Jira description. Registration is
/// permanent (a tag is never un-marked) and is persisted next to the session
/// id store so a daemon restart that resumes the session does not forget it.
///
/// Cheap to clone: every clone shares one registry. The session manager owns
/// it; connections hold a clone so the write path never takes the session
/// manager's lock.
#[derive(Clone)]
pub struct SensitiveTags {
    inner: Arc<RwLock<Registered>>,
    path: Option<Arc<PathBuf>>,
    writer: RegistryWriter,
}

impl Default for SensitiveTags {
    fn default() -> Self {
        Self::in_memory()
    }
}

impl SensitiveTags {
    /// A registry that is not persisted (tests, non-daemon use).
    pub fn in_memory() -> Self {
        Self {
            inner: Arc::new(RwLock::new(Registered::default())),
            path: None,
            writer: Arc::new(write_atomic),
        }
    }

    /// A registry persisted at `path`, seeded from it when it exists.
    pub fn persisted(path: PathBuf) -> Self {
        Self::persisted_with_writer(path, Arc::new(write_atomic))
    }

    /// As [`SensitiveTags::persisted`], writing through `writer` (tests inject
    /// a failing disk).
    ///
    /// Startup is **degraded** when a `sensitive-tags.dirty` sentinel is
    /// present (a previous run failed to persist a registration) or when the
    /// registry cannot be written now. See [`SensitiveTags::note_resumed`].
    pub fn persisted_with_writer(path: PathBuf, writer: RegistryWriter) -> Self {
        let unreadable = |why: &dyn std::fmt::Display| {
            warn!(path = %path.display(), "sensitive-tag registry unreadable ({why}); treating every tag as sensitive");
            Registered { unreadable: true, ..Registered::default() }
        };
        let mut registered = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<Registered>(&bytes).unwrap_or_else(|e| unreadable(&e)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Registered::default(),
            Err(e) => unreadable(&e),
        };
        let tags = Self {
            inner: Arc::new(RwLock::new(Registered::default())),
            path: Some(Arc::new(path)),
            writer,
        };
        if !registered.unreadable {
            // A sentinel, or a registry that cannot be written right now,
            // means registrations may have been lost across this restart.
            let sentinel_present = tags.sentinel_path().is_some_and(|p| p.exists());
            if sentinel_present || !tags.write_registry(&registered) {
                warn!("sensitive-tag registry may have lost registrations; resumed sessions are treated as sensitive");
                registered.degraded = true;
                registered.lost_history = true;
            }
        }
        *tags.inner.write().unwrap() = registered;
        tags
    }

    /// Does the focus `tag` carry (or can it act on) Teri/Fred-derived data?
    pub fn tag_is_sensitive(&self, tag: &str) -> bool {
        let registered = self.inner.read().unwrap();
        is_teri_or_fred_agent(tag) || registered.unreadable || registered.tags.contains_key(tag)
    }

    /// Is a focus with this `tag` running `agent_name` sensitive? A session of
    /// the Fred/Teri agent is, whatever tag it runs under.
    pub fn focus_is_sensitive(&self, tag: &str, agent_name: &str) -> bool {
        self.tag_is_sensitive(tag) || is_teri_or_fred_agent(agent_name)
    }

    /// Was Mother job `job_id` created from a work item?
    pub fn job_is_sensitive(&self, job_id: &str) -> bool {
        let registered = self.inner.read().unwrap();
        registered.unreadable || registered.jobs.contains(job_id)
    }

    /// Register `tag` as sensitive. Idempotent.
    pub fn mark_tag(&self, tag: &str) {
        if is_teri_or_fred_agent(tag) {
            return;
        }
        let mut registered = self.inner.write().unwrap();
        self.register_tag(&mut registered, tag);
    }

    /// Register `tag` (with a fresh opaque id) and persist, unless it is
    /// already registered. Caller holds the write lock.
    fn register_tag(&self, registered: &mut Registered, tag: &str) {
        if !registered.tags.contains_key(tag) {
            registered.tags.insert(tag.to_string(), new_opaque_tag());
            self.persist(registered);
        }
    }

    /// Register Mother job `job_id` as sensitive. Idempotent.
    pub fn mark_job(&self, job_id: &str) {
        let mut registered = self.inner.write().unwrap();
        if registered.jobs.insert(job_id.to_string()) {
            self.persist(&mut registered);
        }
    }

    /// A stored session id for `tag` is being resumed. While the registry is
    /// known to have lost registrations (see [`SensitiveTags::persisted_with_writer`])
    /// an unregistered resumed session may have been work-derived, so it is
    /// registered as sensitive. A healthy registry leaves it alone.
    pub fn note_resumed(&self, tag: &str) {
        let mut registered = self.inner.write().unwrap();
        if registered.lost_history && !is_teri_or_fred_agent(tag) {
            self.register_tag(&mut registered, tag);
        }
    }

    /// The session manager has now registered every stored session as sensitive
    /// ([`SensitiveTags::note_resumed`]), so the registry no longer lacks
    /// anything that can resume. If it can be written, it is current again:
    /// the degraded state and the sentinel go.
    pub fn settle_lost_history(&self) {
        let mut registered = self.inner.write().unwrap();
        if registered.lost_history {
            // Persist as a healthy registry; `persist` leaves `degraded` set
            // only if the write failed, and then history is still lost for
            // the next restart too.
            registered.lost_history = false;
            self.persist(&mut registered);
            registered.lost_history = registered.degraded;
        }
    }

    /// Did the last attempt to write the registry fail, or did this run start
    /// from a registry that may have lost registrations?
    pub fn is_degraded(&self) -> bool {
        self.inner.read().unwrap().degraded
    }

    /// A network peer wrote to `tag`'s session. That session can now be steered
    /// by an unauthenticated peer, so it is denied the Teri/Fred/Mother MCP
    /// tools (see `mcp::tools`). Not persisted: it ends with the daemon.
    pub fn mark_network_driven(&self, tag: &str) {
        self.inner.write().unwrap().network_driven.insert(tag.to_string());
    }

    pub fn is_network_driven(&self, tag: &str) -> bool {
        self.inner.read().unwrap().network_driven.contains(tag)
    }

    /// Total bytes held by the ephemeral opaque-tag map (keys and values).
    pub fn ephemeral_footprint_bytes(&self) -> usize {
        self.inner.read().unwrap().ephemeral_bytes
    }

    /// The stand-in shown to network peers for a sensitive `tag`: stable for
    /// the life of the registration (or, for a tag that is sensitive without
    /// being registered, of this process) and unrelated to the tag's text.
    fn opaque_tag(&self, tag: &str) -> String {
        let mut registered = self.inner.write().unwrap();
        if let Some(opaque) = registered.tags.get(tag) {
            return opaque.clone();
        }
        // The key is attacker-controlled (a network peer pushes whatever tag it
        // likes), so an oversized tag is remembered by a fixed-size digest.
        let key = ephemeral_key(tag);
        if let Some(opaque) = registered.ephemeral.get(key.as_ref()) {
            return opaque.clone();
        }
        let opaque = new_opaque_tag();
        // Bounded in entries and in bytes: past either cap the map restarts,
        // which only changes the ids shown for these unregistered tags.
        let entry_bytes = key.len() + opaque.len();
        if registered.ephemeral.len() >= MAX_EPHEMERAL_OPAQUE_TAGS
            || registered.ephemeral_bytes + entry_bytes > MAX_EPHEMERAL_OPAQUE_BYTES
        {
            registered.ephemeral.clear();
            registered.ephemeral_bytes = 0;
        }
        registered.ephemeral_bytes += entry_bytes;
        registered.ephemeral.insert(key.into_owned(), opaque.clone());
        opaque
    }

    /// Write the registry out. Called with the registry's write lock held, so
    /// concurrent registrations are serialised and the last write on disk is
    /// the latest state.
    ///
    /// A failed write is retried (bounded). If it still fails the registry is
    /// **degraded**: the registration stays in memory, and a sentinel file is
    /// left beside the registry so the next start knows registrations may be
    /// missing from it. A later successful write clears both.
    fn persist(&self, registered: &mut Registered) {
        if self.path.is_none() {
            return;
        }
        if registered.unreadable {
            // Leave the unreadable file for the operator rather than replace
            // it with a registry that forgot everything before this run.
            return;
        }
        if self.write_registry(registered) {
            // Still degraded while the file is known to lack past registrations.
            registered.degraded = registered.lost_history;
            if !registered.lost_history {
                self.clear_sentinel();
            }
        } else {
            registered.degraded = true;
            self.write_sentinel();
        }
    }

    fn write_sentinel(&self) {
        if let Some(sentinel) = self.sentinel_path() {
            if let Err(e) = std::fs::write(&sentinel, b"registrations may be missing from sensitive-tags.json\n") {
                warn!(path = %sentinel.display(), "sensitive-tag registry: could not write the degraded sentinel: {e}");
            }
        }
    }

    fn clear_sentinel(&self) {
        if let Some(sentinel) = self.sentinel_path() {
            let _ = std::fs::remove_file(sentinel);
        }
    }

    /// One bounded write attempt sequence; `true` when the registry reached the disk.
    fn write_registry(&self, registered: &Registered) -> bool {
        let Some(path) = &self.path else { return true };
        let json = match serde_json::to_vec(registered) {
            Ok(j) => j,
            Err(e) => {
                warn!("sensitive-tag registry: serialise failed: {e}");
                return false;
            }
        };
        for attempt in 0..PERSIST_ATTEMPTS {
            match (self.writer)(path, &json) {
                Ok(()) => return true,
                Err(e) => {
                    warn!(path = %path.display(), attempt, "sensitive-tag registry: persist failed: {e}");
                    if attempt + 1 < PERSIST_ATTEMPTS {
                        std::thread::sleep(std::time::Duration::from_millis(5 << attempt));
                    }
                }
            }
        }
        false
    }

    fn sentinel_path(&self) -> Option<PathBuf> {
        self.path.as_ref().map(|p| p.with_file_name("sensitive-tags.dirty"))
    }
}

/// How the registry is written to disk; tests inject a failing writer.
pub type RegistryWriter = Arc<dyn Fn(&Path, &[u8]) -> std::io::Result<()> + Send + Sync>;

tokio::task_local! {
    static WORK_SEND: ();
}

/// Run `fut` as part of a work-item send (`WorkSend`). While it runs,
/// `SessionManager::spawn_session`, `add_or_update_focus` and
/// `send_user_message` register their tag as sensitive **before** anything is
/// spawned, seeded or broadcast, so a network peer can never see the focus a
/// work item is being sent to in the window before `WorkService::send` returns.
///
/// The scope follows the task, not the thread: a [`WorkService`](crate::data::work::WorkService)
/// that hands the work to another task must wrap that task's future in this too.
pub async fn within_work_send<F: std::future::Future>(fut: F) -> F::Output {
    WORK_SEND.scope((), fut).await
}

/// Is the current task inside [`within_work_send`]?
pub fn in_work_send() -> bool {
    WORK_SEND.try_with(|_| ()).is_ok()
}

const MAX_EPHEMERAL_OPAQUE_TAGS: usize = 4096;
/// Total bytes (keys plus ids) the ephemeral map may hold.
const MAX_EPHEMERAL_OPAQUE_BYTES: usize = 256 * 1024;
/// Longest tag kept verbatim as a map key; longer ones are keyed by digest.
const MAX_EPHEMERAL_KEY_LEN: usize = 256;
/// Attempts to write the registry before it is declared degraded.
const PERSIST_ATTEMPTS: u32 = 3;

fn ephemeral_key(tag: &str) -> std::borrow::Cow<'_, str> {
    use std::hash::{Hash, Hasher};
    if tag.len() <= MAX_EPHEMERAL_KEY_LEN {
        return std::borrow::Cow::Borrowed(tag);
    }
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    tag.hash(&mut hasher);
    std::borrow::Cow::Owned(format!("\u{0}h{}:{:016x}", tag.len(), hasher.finish()))
}

fn new_opaque_tag() -> String {
    format!("focus-{}", &uuid::Uuid::new_v4().simple().to_string()[..16])
}

fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)
}

/// The path of the sensitive-tag registry that sits beside a session id store.
pub fn registry_path_beside(store_path: &Path) -> PathBuf {
    store_path.with_file_name("sensitive-tags.json")
}

// ── server → client classification ───────────────────────────────────────────

/// Whether a message carries Teri/Fred data (or requests it).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SensitiveClass {
    Sensitive,
    NotSensitive,
}

impl SensitiveClass {
    pub fn is_sensitive(self) -> bool {
        self == SensitiveClass::Sensitive
    }
}

/// How a daemon-to-client frame is scoped, i.e. what decides whether a network
/// peer may receive it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerClass<'a> {
    /// Teri/Fred/work data itself: never delivered to a network peer.
    Sensitive,
    /// Not Teri/Fred-derived (or knowingly left open, see the module-level
    /// list below). Content that can be, such as focus lists, is trimmed by
    /// [`redact_for_network`] instead.
    Open,
    /// Content of one focus (including a per-focus frame like `PerriState`,
    /// whose tag alone names the focus): delivered only if its tag is not
    /// sensitive.
    Focus(&'a str),
    /// Content of one Mother job: delivered only if the job is not work-derived.
    Job(&'a str),
    /// An activity event: its focus tag, or `None` when unattributed.
    /// Unattributed events are withheld: they may belong to a Teri/Fred
    /// session whose session id the daemon could not resolve.
    Activity(Option<&'a str>),
}

// ── What is NOT gated (read this before trusting the exhaustive matches) ─────
//
// The `match`es below force every `ServerMsg`/`ClientMsg` variant to be
// *classified*, which is NOT a security audit of the daemon. The TCP listener
// is unauthenticated and LAN-bound as a whole; fixing that (authentication,
// rebinding the port) is tracked separately in
// `.claude/wip/nostromd-tcp-47100-exposure/index.md`. Until then these families
// are knowingly reachable by any network peer, because gating them one by one
// would be theatre while `pty_spawn` runs arbitrary commands:
//
//   * client → daemon: `focus_registry_push`, `perri_action`, `mother_action`,
//     `mother_resume`, `decision_answer`, `pty_kill`/`pty_attach`/`pty_resize`,
//     `close_pane`, `rendered_shape`, and `session_*` verbs (attach, send,
//     interrupt, control) on non-sensitive tags. `session_send` writes to an
//     existing session's process: that session is then marked network-driven
//     and loses its `fred.*`/`teri.*`/`mother.*` MCP tools, but it keeps its
//     other tools (`nostromo.*`, `perri.*`) and whatever it already read.
//   * daemon → client: PTY output (`pty_*`), `mother_statusline`, and the pane
//     content / layout / notifications / decisions / activity / transcripts /
//     Perri state of every focus that is NOT a sensitive tag. Pane content of an
//     ordinary dynamic focus can therefore still show whatever its agent put there.
//   * a Teri/Fred-derived focus is only recognised when it is a built-in, was
//     created through `WorkSend` or `create_focus` with seeded context, or runs
//     the `fred`/`teri` agent. Text an agent pastes into some other focus, or
//     a Mother job started from a shell, is not tracked. A Mother job a work
//     item starts is registered when `WorkService::send` returns (its id is not
//     known sooner), so it can appear in a `mother_jobs` list in that window.
//
// What this module DOES guarantee for network peers: nothing Teri/Fred-derived
// that the daemon can identify (the cases above) is delivered or driven through
// any frame family, on the replay, broadcast and targeted paths, AND a network
// peer cannot start a process (`session_spawn` for any agent, `pty_spawn`) or
// type into a PTY (`pty_input`), so it cannot use an ordinary agent session as
// a proxy to the `fred.*`/`teri.*` tools. The guarantee is bounded by the
// unauthenticated listener: it is not a substitute for authentication or for
// binding the port to loopback (tracked in the wip doc above).

/// Classify a daemon-to-client message. Every variant is listed on purpose.
pub fn classify_server_msg(msg: &ServerMsg) -> ServerClass<'_> {
    match msg {
        // Teri/Fred/work data itself.
        ServerMsg::TeriState { .. }
        | ServerMsg::FredState { .. }
        | ServerMsg::WorkSourceStatus { .. }
        | ServerMsg::WorkSnapshot { .. }
        | ServerMsg::TeriPicks { .. }
        | ServerMsg::WorkDetail { .. }
        | ServerMsg::WorkSendPreview { .. }
        | ServerMsg::WorkSendResult { .. } => ServerClass::Sensitive,

        // Scoped to one focus: the transcript, pane content, notifications,
        // decision prompts/details and activity of a focus can all quote
        // mail, todos or Jira text.
        ServerMsg::SessionSpawned { tag, .. }
        | ServerMsg::SessionTurns { tag, .. }
        | ServerMsg::SessionTurnDelta { tag, .. }
        | ServerMsg::SessionState { tag, .. }
        | ServerMsg::SessionPermissionRequest { tag, .. }
        | ServerMsg::SessionExited { tag, .. }
        | ServerMsg::SessionDown { tag, .. }
        | ServerMsg::SessionSummaryUpdate { tag, .. }
        | ServerMsg::FocusLayout { tag, .. }
        | ServerMsg::PaneContent { tag, .. }
        | ServerMsg::DecisionRequest { tag, .. }
        | ServerMsg::DecisionResolved { tag, .. }
        | ServerMsg::Notification { tag, .. }
        | ServerMsg::ActivitySnapshot { tag, .. }
        | ServerMsg::PerriState { tag, .. } => ServerClass::Focus(tag),

        ServerMsg::Activity(event) => ServerClass::Activity(event.focus_tag.as_deref()),

        // Scoped to one Mother job. A job started from a work item carries
        // its plan/title/transcript; classified by job id (no focus tag).
        ServerMsg::MotherPeek { job_id, .. } => ServerClass::Job(job_id),
        ServerMsg::MotherAwaitDetected(job) => ServerClass::Job(&job.id),

        // Lists whose entries are filtered/trimmed by `redact_for_network`.
        ServerMsg::FocusListResp { .. }
        | ServerMsg::FocusRegistryUpdated { .. }
        | ServerMsg::FocusCreated { .. }
        | ServerMsg::SessionListResp { .. }
        | ServerMsg::MotherJobs { .. } => ServerClass::Open,

        // No Teri/Fred-derived content: handshake, liveness, counters, health
        // booleans, the withheld notice, and the knowingly-open families
        // listed above.
        ServerMsg::Welcome { .. }
        | ServerMsg::MotherStatusline(_)
        | ServerMsg::Pong
        | ServerMsg::Error { .. }
        | ServerMsg::PtySpawned { .. }
        | ServerMsg::PtyOutput { .. }
        | ServerMsg::PtyExited { .. }
        | ServerMsg::PtyScrollback { .. }
        | ServerMsg::PtyAttached { .. }
        | ServerMsg::PtyDetach { .. }
        | ServerMsg::PtyListResp { .. }
        | ServerMsg::PtyIdentity { .. }
        | ServerMsg::ActivityHealth { .. }
        | ServerMsg::Withheld { .. }
        | ServerMsg::DaemonReconnected => ServerClass::Open,
    }
}

/// Is `msg` Teri/Fred/work data *itself* (as opposed to focus-scoped content)?
pub fn is_sensitive_server_msg(msg: &ServerMsg) -> SensitiveClass {
    match classify_server_msg(msg) {
        ServerClass::Sensitive => SensitiveClass::Sensitive,
        ServerClass::Open
        | ServerClass::Focus(_)
        | ServerClass::Job(_)
        | ServerClass::Activity(_) => SensitiveClass::NotSensitive,
    }
}

/// True for the targeted refusal frames a network peer is answered with.
pub fn is_refusal(msg: &ServerMsg) -> bool {
    let is_secure_refusal = |code: &str| code == "requires_secure_connection";
    match msg {
        ServerMsg::WorkDetail { result: WorkResult::Err(e), .. }
        | ServerMsg::WorkSendPreview { result: WorkResult::Err(e), .. }
        | ServerMsg::WorkSendResult { result: WorkResult::Err(e), .. } => {
            is_secure_refusal(&e.code)
        }
        ServerMsg::Error { message } => message.starts_with("requires_secure_connection"),
        _ => false,
    }
}

/// May `msg` be written to a peer of this trust, on **any** path (broadcast,
/// targeted, replay)? A local peer may receive everything. A network peer
/// never receives Teri/Fred/work data, nor content scoped to a sensitive focus
/// or work-derived job, whatever topics it subscribed to (an empty list means
/// "everything", which must not include these). Runs before topic matching.
pub fn may_receive(trust: PeerTrust, msg: &ServerMsg, tags: &SensitiveTags) -> bool {
    if !trust.is_network() || is_refusal(msg) {
        return true;
    }
    match classify_server_msg(msg) {
        ServerClass::Sensitive => false,
        ServerClass::Open => true,
        ServerClass::Focus(tag) => !tags.tag_is_sensitive(tag),
        ServerClass::Job(job_id) => !tags.job_is_sensitive(job_id),
        ServerClass::Activity(Some(tag)) => !tags.tag_is_sensitive(tag),
        ServerClass::Activity(None) => false,
    }
}

/// What a peer of this trust is actually sent for `msg`: `None` when it is
/// withheld, otherwise the frame (trimmed for a network peer).
pub fn outbound(trust: PeerTrust, msg: ServerMsg, tags: &SensitiveTags) -> Option<ServerMsg> {
    if !may_receive(trust, &msg, tags) {
        return None;
    }
    Some(if trust.is_network() { redact_for_network(msg, tags) } else { msg })
}

// ── client → server classification ───────────────────────────────────────────

/// Classify a client-to-daemon message. `true` means a network peer must be
/// refused with `requires_secure_connection`, whatever tag it names. (Requests
/// that name a sensitive *tag* are caught by [`targets_sensitive_session`].)
pub fn is_sensitive_client_msg(msg: &ClientMsg) -> bool {
    match msg {
        ClientMsg::WorkDetailRequest { .. }
        | ClientMsg::WorkRefresh { .. }
        | ClientMsg::PicksRefresh { .. }
        | ClientMsg::WorkSendPreviewRequest { .. }
        | ClientMsg::WorkSend { .. }
        | ClientMsg::FredSeed { .. } => true,

        ClientMsg::Hello { .. }
        | ClientMsg::Subscribe { .. }
        | ClientMsg::Ping
        | ClientMsg::PtySpawn { .. }
        | ClientMsg::PtyAttach { .. }
        | ClientMsg::PtyDetach { .. }
        | ClientMsg::PtyInput { .. }
        | ClientMsg::PtyResize { .. }
        | ClientMsg::PtyKill { .. }
        | ClientMsg::PtyList
        | ClientMsg::SessionSpawn { .. }
        | ClientMsg::SessionAttach { .. }
        | ClientMsg::SessionDetach { .. }
        | ClientMsg::SessionSend { .. }
        | ClientMsg::ClosePane { .. }
        | ClientMsg::SessionInterrupt { .. }
        | ClientMsg::SessionControl { .. }
        | ClientMsg::SessionAnswerPermission { .. }
        | ClientMsg::SessionList
        | ClientMsg::FocusRegistryPush { .. }
        | ClientMsg::FocusList
        | ClientMsg::MotherAction { .. }
        | ClientMsg::MotherResume { .. }
        | ClientMsg::PerriAction { .. }
        | ClientMsg::DecisionAnswer { .. }
        | ClientMsg::ActivitySnapshotRequest { .. }
        | ClientMsg::RenderedShape { .. } => false,
    }
}

/// Does `msg` read, drive or create a session/focus (or Mother job) that
/// carries Teri/Fred data? A network peer's such request is refused with
/// `requires_secure_connection` before any side effect. Spawning is refused
/// for a sensitive tag *and* for the `fred`/`teri` agent under any tag (that
/// session would have mail/calendar/todo tools). `SessionDetach` is allowed:
/// it only releases the peer's own attachment. `DecisionAnswer` names only a
/// request id; the server resolves it to its tag (see `handle_client_msg`).
pub fn targets_sensitive_session(msg: &ClientMsg, tags: &SensitiveTags) -> bool {
    match msg {
        ClientMsg::SessionSpawn { tag, agent_name, .. } => {
            tags.focus_is_sensitive(tag, agent_name)
        }
        ClientMsg::MotherAction { job_id, .. } | ClientMsg::MotherResume { job_id, .. } => {
            tags.job_is_sensitive(job_id)
        }
        ClientMsg::SessionAttach { tag }
        | ClientMsg::SessionSend { tag, .. }
        | ClientMsg::SessionInterrupt { tag }
        | ClientMsg::SessionControl { tag, .. }
        | ClientMsg::SessionAnswerPermission { tag, .. }
        | ClientMsg::ClosePane { tag, .. }
        | ClientMsg::ActivitySnapshotRequest { tag }
        | ClientMsg::RenderedShape { tag, .. } => tags.tag_is_sensitive(tag),

        ClientMsg::Hello { .. }
        | ClientMsg::Subscribe { .. }
        | ClientMsg::Ping
        | ClientMsg::PtySpawn { .. }
        | ClientMsg::PtyAttach { .. }
        | ClientMsg::PtyDetach { .. }
        | ClientMsg::PtyInput { .. }
        | ClientMsg::PtyResize { .. }
        | ClientMsg::PtyKill { .. }
        | ClientMsg::PtyList
        | ClientMsg::SessionDetach { .. }
        | ClientMsg::SessionList
        | ClientMsg::FocusRegistryPush { .. }
        | ClientMsg::FocusList
        | ClientMsg::PerriAction { .. }
        | ClientMsg::DecisionAnswer { .. }
        | ClientMsg::WorkDetailRequest { .. }
        | ClientMsg::WorkRefresh { .. }
        | ClientMsg::PicksRefresh { .. }
        | ClientMsg::WorkSendPreviewRequest { .. }
        | ClientMsg::WorkSend { .. }
        | ClientMsg::FredSeed { .. } => false,
    }
}

/// Does `msg` start a process, or write to one the peer did not start itself?
/// Refused for a network peer whatever it names: a session of **any** agent
/// is hosted with the MCP bridge, whose `fred.*`/`teri.*`/`mother.*` tools
/// would make the daemon fetch Teri/Fred data and stream it back as an
/// ordinary transcript, and `pty_spawn`/`pty_input` run commands as the user.
///
/// Until the listener is authenticated an iOS client on the LAN therefore
/// cannot start sessions or PTYs. It can still attach to, and send to,
/// non-sensitive sessions the Mac started (such a session loses those tools
/// once a network peer has written to it, see
/// [`SensitiveTags::mark_network_driven`]).
pub fn starts_or_feeds_process(msg: &ClientMsg) -> bool {
    match msg {
        ClientMsg::SessionSpawn { .. } | ClientMsg::PtySpawn { .. } | ClientMsg::PtyInput { .. } => {
            true
        }

        ClientMsg::Hello { .. }
        | ClientMsg::Subscribe { .. }
        | ClientMsg::Ping
        | ClientMsg::PtyAttach { .. }
        | ClientMsg::PtyDetach { .. }
        | ClientMsg::PtyResize { .. }
        | ClientMsg::PtyKill { .. }
        | ClientMsg::PtyList
        | ClientMsg::SessionAttach { .. }
        | ClientMsg::SessionDetach { .. }
        | ClientMsg::SessionSend { .. }
        | ClientMsg::ClosePane { .. }
        | ClientMsg::SessionInterrupt { .. }
        | ClientMsg::SessionControl { .. }
        | ClientMsg::SessionAnswerPermission { .. }
        | ClientMsg::SessionList
        | ClientMsg::FocusRegistryPush { .. }
        | ClientMsg::FocusList
        | ClientMsg::MotherAction { .. }
        | ClientMsg::MotherResume { .. }
        | ClientMsg::PerriAction { .. }
        | ClientMsg::DecisionAnswer { .. }
        | ClientMsg::ActivitySnapshotRequest { .. }
        | ClientMsg::RenderedShape { .. }
        | ClientMsg::WorkDetailRequest { .. }
        | ClientMsg::WorkRefresh { .. }
        | ClientMsg::PicksRefresh { .. }
        | ClientMsg::WorkSendPreviewRequest { .. }
        | ClientMsg::WorkSend { .. }
        | ClientMsg::FredSeed { .. } => false,
    }
}

/// Must a network peer's `msg` be refused? (Any family above.)
pub fn refuse_for_network(msg: &ClientMsg, tags: &SensitiveTags) -> bool {
    is_sensitive_client_msg(msg) || targets_sensitive_session(msg, tags) || starts_or_feeds_process(msg)
}

// ── trimming for network peers ───────────────────────────────────────────────

/// Strip from a focus's metadata what a network peer must not see: the
/// absolute project path, the work-item label (a Jira key or doc title), the
/// first-user-message summary (seeded context), and, for a sensitive focus,
/// the agent-supplied title and the tag (the tag of a work-derived focus is a
/// slug of that title). A built-in `fred`/`teri` tag is public.
fn redact_meta(meta: &mut FocusMeta, tags: &SensitiveTags) {
    meta.project_path = None;
    meta.label = None;
    meta.session_summary = None;
    if tags.focus_is_sensitive(&meta.tag, &meta.agent_name) {
        meta.display_name = meta.agent_name.clone();
        // Only the exact built-in names are public. Every other sensitive tag
        // (registered, alias-looking, or sensitive because the registry is
        // unreadable) is replaced, never passed through.
        if meta.tag != "fred" && meta.tag != "teri" {
            meta.tag = tags.opaque_tag(&meta.tag);
        }
    }
}

/// Trim an otherwise-deliverable frame for a network peer; see
/// [`redact_meta`], plus: session and Mother-job lists drop their sensitive
/// entries.
pub fn redact_for_network(msg: ServerMsg, tags: &SensitiveTags) -> ServerMsg {
    fn redact_all(mut metas: Vec<FocusMeta>, tags: &SensitiveTags) -> Vec<FocusMeta> {
        for m in &mut metas {
            redact_meta(m, tags);
        }
        metas
    }
    match msg {
        ServerMsg::FocusListResp { focuses } => {
            ServerMsg::FocusListResp { focuses: redact_all(focuses, tags) }
        }
        ServerMsg::FocusRegistryUpdated { focuses } => {
            ServerMsg::FocusRegistryUpdated { focuses: redact_all(focuses, tags) }
        }
        ServerMsg::FocusCreated { mut meta } => {
            redact_meta(&mut meta, tags);
            ServerMsg::FocusCreated { meta }
        }
        ServerMsg::SessionListResp { mut sessions } => {
            sessions.retain(|s| !tags.focus_is_sensitive(&s.tag, &s.agent_name));
            ServerMsg::SessionListResp { sessions }
        }
        ServerMsg::MotherJobs { mut jobs } => {
            jobs.retain(|j| !tags.job_is_sensitive(&j.id));
            ServerMsg::MotherJobs { jobs }
        }
        other => other,
    }
}

/// The topics withheld from network peers, as announced in `Withheld`.
pub fn withheld_topics() -> Vec<Topic> {
    vec![Topic::Fred, Topic::Teri, Topic::Work]
}

/// The `Withheld` notice sent once to a network peer after it subscribes.
pub fn withheld_msg() -> ServerMsg {
    ServerMsg::Withheld {
        topics: withheld_topics(),
        reason: "requires_secure_connection".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::work::{
        PicksSnapshot, SourceState, SourceStatus, WorkResult, WorkSource,
    };

    #[test]
    fn unix_peers_are_local_and_tcp_peers_are_network() {
        assert_eq!(PeerTrust::from_transport(Transport::Unix), PeerTrust::LocalOther);
        assert_eq!(PeerTrust::from_transport(Transport::Tcp), PeerTrust::Tcp);
        assert!(!PeerTrust::LocalOther.is_network());
        assert!(!PeerTrust::OperatorApp.is_network());
        assert!(PeerTrust::Tcp.is_network());
    }

    #[test]
    fn teri_fred_and_work_broadcasts_are_sensitive() {
        let status = SourceStatus {
            source: WorkSource::Jira,
            state: SourceState::Fresh,
            updated_at: None,
            reason: None,
            retry_at: None,
            count: 0,
            group_errors: vec![],
        };
        let sensitive = [
            ServerMsg::TeriState { todos: Default::default() },
            ServerMsg::FredState { mailbox: Default::default(), calendar: Default::default() },
            ServerMsg::WorkSourceStatus { status },
            ServerMsg::WorkSnapshot { source: WorkSource::Todos, group: None, items: vec![] },
            ServerMsg::TeriPicks { picks: PicksSnapshot::default() },
            ServerMsg::WorkDetail { request_id: "r".into(), result: WorkResult::err("x", "y") },
            ServerMsg::WorkSendPreview { request_id: "r".into(), result: WorkResult::err("x", "y") },
            ServerMsg::WorkSendResult { request_id: "r".into(), result: WorkResult::err("x", "y") },
        ];
        for msg in &sensitive {
            assert!(is_sensitive_server_msg(msg).is_sensitive(), "{msg:?}");
            let tags = SensitiveTags::in_memory();
            assert!(!may_receive(PeerTrust::Tcp, msg, &tags), "{msg:?}");
            assert!(may_receive(PeerTrust::LocalOther, msg, &tags), "{msg:?}");
        }
    }

    #[test]
    fn non_sensitive_broadcasts_still_reach_network_peers() {
        let msg = ServerMsg::FocusRegistryUpdated { focuses: vec![] };
        assert!(!is_sensitive_server_msg(&msg).is_sensitive());
        let tags = SensitiveTags::in_memory();
        assert!(may_receive(PeerTrust::Tcp, &msg, &tags));
        assert!(may_receive(PeerTrust::Tcp, &withheld_msg(), &tags));
    }

    #[test]
    fn the_new_client_requests_are_all_sensitive() {
        let sensitive = [
            ClientMsg::WorkDetailRequest { request_id: "r".into(), item_id: "i".into() },
            ClientMsg::WorkRefresh { source: None, fred: false },
            ClientMsg::PicksRefresh { reason: "manual".into() },
            ClientMsg::WorkSendPreviewRequest { request_id: "r".into(), item_id: "i".into() },
            ClientMsg::WorkSend {
                request_id: "r".into(),
                item_id: "i".into(),
                destination: "focus".into(),
                agent: "cody".into(),
                working_directory: None,
                label: "l".into(),
                context: "c".into(),
                allow_duplicate: false,
            },
            ClientMsg::FredSeed { request_id: "r".into(), text: "t".into() },
        ];
        for msg in &sensitive {
            assert!(is_sensitive_client_msg(msg), "{msg:?}");
        }
        assert!(!is_sensitive_client_msg(&ClientMsg::Ping));
        assert!(!is_sensitive_client_msg(&ClientMsg::SessionList));
    }

    #[test]
    fn withheld_names_fred_teri_and_work() {
        match withheld_msg() {
            ServerMsg::Withheld { topics, reason } => {
                assert_eq!(topics, vec![Topic::Fred, Topic::Teri, Topic::Work]);
                assert_eq!(reason, "requires_secure_connection");
            }
            other => panic!("expected Withheld, got {other:?}"),
        }
    }
    #[test]
    fn network_peers_never_see_a_focus_project_path() {
        let meta = FocusMeta {
            tag: "t".into(),
            display_name: "T".into(),
            agent_name: "cody".into(),
            project_name: None,
            org: None,
            is_built_in: false,
            session_summary: None,
            label: Some("L".into()),
            project_path: Some("/Users/x/repo".into()),
            select_for_client: None,
        };
        for msg in [
            ServerMsg::FocusCreated { meta: meta.clone() },
            ServerMsg::FocusRegistryUpdated { focuses: vec![meta.clone()] },
            ServerMsg::FocusListResp { focuses: vec![meta.clone()] },
        ] {
            let json =
                serde_json::to_string(&redact_for_network(msg, &SensitiveTags::in_memory())).unwrap();
            assert!(!json.contains("/Users/x/repo"), "path leaked: {json}");
            // The label is withheld from network peers too (it can be a Jira
            // key or doc title); an ordinary focus's identity is kept.
            assert!(!json.contains("\"label\""), "label leaked: {json}");
            assert!(json.contains("\"tag\":\"t\""), "other fields kept: {json}");
        }
    }

    fn tags_with(tag: &str) -> SensitiveTags {
        let tags = SensitiveTags::in_memory();
        tags.mark_tag(tag);
        tags
    }

    #[test]
    fn fred_and_teri_are_sensitive_whatever_their_case_and_others_only_once_registered() {
        let tags = SensitiveTags::in_memory();
        for tag in ["fred", "teri", "Fred", "TERI"] {
            assert!(tags.tag_is_sensitive(tag), "{tag}");
        }
        assert!(!tags.tag_is_sensitive("cody-core-1"));
        tags.mark_tag("cody-core-1");
        assert!(tags.tag_is_sensitive("cody-core-1"));
        // A clone shares the registry.
        let clone = tags.clone();
        clone.mark_tag("cody-core-2");
        assert!(tags.tag_is_sensitive("cody-core-2"));
    }

    #[test]
    fn registered_tags_and_jobs_survive_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_path_beside(&dir.path().join("daemon-sessions.json"));
        let first = SensitiveTags::persisted(path.clone());
        first.mark_tag("cody-core-1");
        first.mark_job("job-9");

        let second = SensitiveTags::persisted(path);
        assert!(second.tag_is_sensitive("cody-core-1"));
        assert!(second.job_is_sensitive("job-9"));
        assert!(!second.tag_is_sensitive("cody-other"));
    }

    #[test]
    fn session_verbs_on_a_sensitive_tag_or_for_a_fred_teri_agent_are_refused_for_network_peers() {
        let tags = tags_with("cody-core-1");
        let attach = |tag: &str| ClientMsg::SessionAttach { tag: tag.into() };
        assert!(refuse_for_network(&attach("fred"), &tags));
        assert!(refuse_for_network(&attach("cody-core-1"), &tags));
        assert!(!refuse_for_network(&attach("cody-other"), &tags));
        let spawn = |tag: &str, agent: &str| ClientMsg::SessionSpawn {
            tag: tag.into(),
            agent_name: agent.into(),
            view_name: "v".into(),
            cwd: None,
            session_id: None,
            remote_control: false,
        };
        assert!(refuse_for_network(&spawn("anything", "fred"), &tags));
        assert!(refuse_for_network(&spawn("anything", "Teri"), &tags));
        // A spawn for any agent is refused: an ordinary agent's session is a
        // proxy to the Teri/Fred tools (see `starts_or_feeds_process`).
        assert!(refuse_for_network(&spawn("anything", "cody"), &tags));
        // Detaching only releases the peer's own attachment.
        assert!(!refuse_for_network(&ClientMsg::SessionDetach { tag: "fred".into() }, &tags));
    }

    #[test]
    fn focus_scoped_frames_follow_their_tag_and_unattributed_activity_is_withheld() {
        let tags = tags_with("cody-core-1");
        let notification = |tag: &str| ServerMsg::Notification {
            tag: tag.into(),
            level: crate::ipc::protocol::NotificationLevel::Info,
            message: "m".into(),
        };
        assert!(!may_receive(PeerTrust::Tcp, &notification("fred"), &tags));
        assert!(!may_receive(PeerTrust::Tcp, &notification("cody-core-1"), &tags));
        assert!(may_receive(PeerTrust::Tcp, &notification("cody-other"), &tags));
        assert!(may_receive(PeerTrust::LocalOther, &notification("fred"), &tags));

        let event = |focus_tag: Option<&str>| {
            ServerMsg::Activity(crate::agent_bus::ActivityEvent {
                ts: chrono::Utc::now(),
                agent: "a".into(),
                kind: "tool_use".into(),
                summary: "s".into(),
                focus_tag: focus_tag.map(str::to_string),
                session_id: None,
                agent_id: None,
                agent_type: None,
                parent_agent_id: None,
                tool_name: None,
                tool_use_id: None,
                cwd: None,
                seq: None,
            })
        };
        assert!(may_receive(PeerTrust::Tcp, &event(Some("cody-other")), &tags));
        assert!(!may_receive(PeerTrust::Tcp, &event(Some("teri")), &tags));
        assert!(!may_receive(PeerTrust::Tcp, &event(None), &tags));
        assert!(may_receive(PeerTrust::LocalOther, &event(None), &tags));
    }

    #[test]
    fn refusals_are_always_deliverable() {
        let refusal = ServerMsg::WorkSendResult {
            request_id: "r".into(),
            result: WorkResult::Err(crate::data::work::WorkError::requires_secure_connection()),
        };
        assert!(may_receive(PeerTrust::Tcp, &refusal, &SensitiveTags::in_memory()));
    }

    #[test]
    fn a_sensitive_focus_shows_a_network_peer_only_its_agent_and_an_opaque_tag() {
        let tags = tags_with("cody-secret-jira-title");
        let meta = |tag: &str, agent: &str| FocusMeta {
            tag: tag.into(),
            display_name: "Cody on SECRET".into(),
            agent_name: agent.into(),
            project_name: None,
            org: None,
            is_built_in: false,
            session_summary: Some("SUMMARY".into()),
            label: Some("LABEL".into()),
            project_path: Some("/Users/x".into()),
            select_for_client: None,
        };
        let ServerMsg::FocusCreated { meta: derived } = redact_for_network(
            ServerMsg::FocusCreated { meta: meta("cody-secret-jira-title", "cody") },
            &tags,
        ) else {
            panic!("expected FocusCreated");
        };
        assert_eq!(derived.display_name, "cody");
        assert!(!derived.tag.contains("secret"), "{}", derived.tag);
        // The opaque tag is stable, so a client can still tell focuses apart.
        assert_eq!(derived.tag, tags.opaque_tag("cody-secret-jira-title"));
        assert_ne!(derived.tag, tags.opaque_tag("cody-other"));

        let ServerMsg::FocusCreated { meta: fred } =
            redact_for_network(ServerMsg::FocusCreated { meta: meta("fred", "fred") }, &tags)
        else {
            panic!("expected FocusCreated");
        };
        assert_eq!((fred.tag.as_str(), fred.display_name.as_str()), ("fred", "fred"));
        assert!(fred.label.is_none() && fred.session_summary.is_none() && fred.project_path.is_none());
    }

    #[test]
    fn session_lists_for_network_peers_omit_sensitive_sessions() {
        use crate::ipc::protocol::SessionInfo;
        use crate::ipc::stream_json::SessionState;
        let info = |tag: &str, agent: &str| SessionInfo {
            tag: tag.into(),
            agent_name: agent.into(),
            view_name: "v".into(),
            session_id: None,
            alive: true,
            remote_control: false,
            state: SessionState::Idle,
            stop_reason: None,
        };
        let tags = tags_with("cody-core-1");
        let ServerMsg::SessionListResp { sessions } = redact_for_network(
            ServerMsg::SessionListResp {
                sessions: vec![
                    info("fred", "fred"),
                    info("cody-core-1", "cody"),
                    info("renamed", "teri"),
                    info("cody-ok", "cody"),
                ],
            },
            &tags,
        ) else {
            panic!("expected SessionListResp");
        };
        assert_eq!(sessions.iter().map(|s| s.tag.as_str()).collect::<Vec<_>>(), vec!["cody-ok"]);
    }

    #[test]
    fn an_unreadable_registry_fails_closed_and_is_left_untouched() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_path_beside(&dir.path().join("daemon-sessions.json"));
        std::fs::write(&path, b"{not json").unwrap();

        let tags = SensitiveTags::persisted(path.clone());
        assert!(tags.tag_is_sensitive("cody-anything"));
        assert!(tags.job_is_sensitive("any-job"));
        tags.mark_tag("cody-x");
        assert_eq!(std::fs::read(&path).unwrap(), b"{not json", "must not overwrite the evidence");
    }

    #[test]
    fn a_sensitive_tag_is_never_passed_through_to_a_network_peer_even_when_unregistered() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_path_beside(&dir.path().join("daemon-sessions.json"));
        std::fs::write(&path, b"{not json").unwrap(); // unreadable: every tag is sensitive
        for tags in [SensitiveTags::persisted(path), SensitiveTags::in_memory()] {
            for (tag, agent) in [("cody-secret-title", "cody"), ("x:fred", "cody"), ("anything", "teri:teri")] {
                let meta = FocusMeta {
                    tag: tag.into(),
                    display_name: "SECRET".into(),
                    agent_name: agent.into(),
                    project_name: None,
                    org: None,
                    is_built_in: false,
                    session_summary: None,
                    label: None,
                    project_path: None,
                    select_for_client: None,
                };
                let ServerMsg::FocusCreated { meta } =
                    redact_for_network(ServerMsg::FocusCreated { meta }, &tags)
                else {
                    panic!("expected FocusCreated");
                };
                let sensitive = tags.tag_is_sensitive(tag) || is_teri_or_fred_agent(agent);
                if sensitive {
                    assert_ne!(meta.tag, tag, "{tag} passed through");
                    assert!(!meta.tag.contains("secret") && !meta.tag.contains("fred"), "{}", meta.tag);
                    assert_eq!(meta.display_name, agent);
                } else {
                    assert_eq!(meta.tag, tag);
                }
            }
        }
    }

    #[test]
    fn mother_verbs_on_a_work_derived_job_are_refused_for_network_peers() {
        let tags = SensitiveTags::in_memory();
        tags.mark_job("job-work");
        let action = |id: &str| ClientMsg::MotherAction {
            job_id: id.into(),
            action: crate::ipc::protocol::MotherActionKind::Cancel,
        };
        let resume = |id: &str| ClientMsg::MotherResume { job_id: id.into(), answer: "a".into() };
        assert!(refuse_for_network(&action("job-work"), &tags));
        assert!(refuse_for_network(&resume("job-work"), &tags));
        assert!(!refuse_for_network(&action("job-plain"), &tags));
        assert!(!refuse_for_network(&resume("job-plain"), &tags));
    }

    // ── round 3 ───────────────────────────────────────────────────────────────

    use crate::ipc::protocol::{MotherActionKind, PermissionDecision, SessionAction};
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    /// One of every `ClientMsg` variant, for exhaustive classification checks.
    fn every_client_msg() -> Vec<ClientMsg> {
        vec![
            ClientMsg::Hello { client_id: "c".into(), protocol_version: 4 },
            ClientMsg::Subscribe { topics: vec![], renders_decisions: false },
            ClientMsg::Ping,
            ClientMsg::PtySpawn {
                pty_id: "p".into(),
                cmd: "/bin/sh".into(),
                args: vec![],
                cols: 80,
                rows: 24,
                cwd: None,
                client_tag: "t".into(),
            },
            ClientMsg::PtyAttach { pty_id: "p".into() },
            ClientMsg::PtyDetach { pty_id: "p".into() },
            ClientMsg::PtyInput { pty_id: "p".into(), bytes: b"ls\n".to_vec() },
            ClientMsg::PtyResize { pty_id: "p".into(), cols: 80, rows: 24 },
            ClientMsg::PtyKill { pty_id: "p".into() },
            ClientMsg::PtyList,
            ClientMsg::SessionSpawn {
                tag: "x1".into(),
                agent_name: "claude".into(),
                view_name: "v".into(),
                cwd: Some("/tmp".into()),
                session_id: None,
                remote_control: false,
            },
            ClientMsg::SessionAttach { tag: "x1".into() },
            ClientMsg::SessionDetach { tag: "x1".into() },
            ClientMsg::SessionSend { tag: "x1".into(), text: "t".into(), images: vec![] },
            ClientMsg::ClosePane { tag: "x1".into(), pane_id: "p".into() },
            ClientMsg::SessionInterrupt { tag: "x1".into() },
            ClientMsg::SessionControl { tag: "x1".into(), action: SessionAction::Stop },
            ClientMsg::SessionAnswerPermission {
                tag: "x1".into(),
                request_id: "r".into(),
                decision: PermissionDecision::Allow,
            },
            ClientMsg::SessionList,
            ClientMsg::FocusRegistryPush { focuses: vec![] },
            ClientMsg::FocusList,
            ClientMsg::MotherAction { job_id: "j".into(), action: MotherActionKind::Cancel },
            ClientMsg::MotherResume { job_id: "j".into(), answer: "a".into() },
            ClientMsg::PerriAction { action: "clear".into(), pr_number: None, repo: None, tag: None },
            ClientMsg::DecisionAnswer { request_id: "r".into(), choice_id: None },
            ClientMsg::ActivitySnapshotRequest { tag: "x1".into() },
            ClientMsg::RenderedShape {
                tag: "x1".into(),
                window_id: "w".into(),
                pane_ids: vec![],
                rendered_at: chrono::Utc::now(),
            },
            ClientMsg::WorkDetailRequest { request_id: "r".into(), item_id: "i".into() },
            ClientMsg::WorkRefresh { source: None, fred: false },
            ClientMsg::PicksRefresh { reason: "manual".into() },
            ClientMsg::WorkSendPreviewRequest { request_id: "r".into(), item_id: "i".into() },
            ClientMsg::WorkSend {
                request_id: "r".into(),
                item_id: "i".into(),
                destination: "focus".into(),
                agent: "cody".into(),
                working_directory: None,
                label: "l".into(),
                context: "c".into(),
                allow_duplicate: false,
            },
            ClientMsg::FredSeed { request_id: "r".into(), text: "t".into() },
        ]
    }

    /// The independent oracle: which requests start a process or write to one.
    /// Deliberately a wildcard-free `match`: adding a `ClientMsg` variant breaks
    /// this test's build until someone decides which side it falls on.
    fn oracle_starts_or_feeds_process(msg: &ClientMsg) -> bool {
        match msg {
            ClientMsg::SessionSpawn { .. } | ClientMsg::PtySpawn { .. } | ClientMsg::PtyInput { .. } => true,
            ClientMsg::Hello { .. }
            | ClientMsg::Subscribe { .. }
            | ClientMsg::Ping
            | ClientMsg::PtyAttach { .. }
            | ClientMsg::PtyDetach { .. }
            | ClientMsg::PtyResize { .. }
            | ClientMsg::PtyKill { .. }
            | ClientMsg::PtyList
            | ClientMsg::SessionAttach { .. }
            | ClientMsg::SessionDetach { .. }
            | ClientMsg::SessionSend { .. }
            | ClientMsg::ClosePane { .. }
            | ClientMsg::SessionInterrupt { .. }
            | ClientMsg::SessionControl { .. }
            | ClientMsg::SessionAnswerPermission { .. }
            | ClientMsg::SessionList
            | ClientMsg::FocusRegistryPush { .. }
            | ClientMsg::FocusList
            | ClientMsg::MotherAction { .. }
            | ClientMsg::MotherResume { .. }
            | ClientMsg::PerriAction { .. }
            | ClientMsg::DecisionAnswer { .. }
            | ClientMsg::ActivitySnapshotRequest { .. }
            | ClientMsg::RenderedShape { .. }
            | ClientMsg::WorkDetailRequest { .. }
            | ClientMsg::WorkRefresh { .. }
            | ClientMsg::PicksRefresh { .. }
            | ClientMsg::WorkSendPreviewRequest { .. }
            | ClientMsg::WorkSend { .. }
            | ClientMsg::FredSeed { .. } => false,
        }
    }

    #[test]
    fn starts_or_feeds_process_is_true_for_session_spawn_pty_spawn_and_pty_input_and_for_nothing_else() {
        for msg in every_client_msg() {
            assert_eq!(starts_or_feeds_process(&msg), oracle_starts_or_feeds_process(&msg), "{msg:?}");
        }
    }

    #[test]
    fn starts_or_feeds_process_does_not_depend_on_the_agent_or_the_tag() {
        for (tag, agent) in [("x1", "claude"), ("cody-1", "cody"), ("fred", "fred"), ("", ""), ("x:fred", "teri:teri")] {
            let spawn = ClientMsg::SessionSpawn {
                tag: tag.into(),
                agent_name: agent.into(),
                view_name: "v".into(),
                cwd: None,
                session_id: None,
                remote_control: false,
            };
            assert!(starts_or_feeds_process(&spawn), "{tag:?}/{agent:?}");
        }
    }

    #[test]
    fn a_network_peer_is_refused_every_process_starting_or_feeding_request_whatever_the_tag_or_agent() {
        let tags = SensitiveTags::in_memory();
        for msg in every_client_msg().iter().filter(|m| oracle_starts_or_feeds_process(m)) {
            assert!(refuse_for_network(msg, &tags), "{msg:?} must be refused for a network peer");
        }
        // Still refused for an agent and tag nobody would call sensitive.
        let spawn = ClientMsg::SessionSpawn {
            tag: "x1".into(),
            agent_name: "claude".into(),
            view_name: "v".into(),
            cwd: Some("/tmp".into()),
            session_id: None,
            remote_control: false,
        };
        assert!(refuse_for_network(&spawn, &tags));
    }

    #[test]
    fn a_network_peer_may_still_attach_send_detach_and_list_for_an_ordinary_session() {
        let tags = SensitiveTags::in_memory();
        for msg in [
            ClientMsg::SessionAttach { tag: "cody-x".into() },
            ClientMsg::SessionSend { tag: "cody-x".into(), text: "hi".into(), images: vec![] },
            ClientMsg::SessionDetach { tag: "cody-x".into() },
            ClientMsg::SessionList,
            ClientMsg::Ping,
        ] {
            assert!(!refuse_for_network(&msg, &tags), "{msg:?}");
        }
    }

    // ── work-send scope ───────────────────────────────────────────────────────

    #[tokio::test]
    async fn the_work_send_scope_is_visible_inside_it_across_awaits_and_only_inside_it() {
        assert!(!in_work_send());
        within_work_send(async {
            assert!(in_work_send());
            tokio::task::yield_now().await;
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            assert!(in_work_send(), "the scope must survive await points");
        })
        .await;
        assert!(!in_work_send(), "the scope ends with the future");
    }

    #[tokio::test]
    async fn within_work_send_returns_the_value_of_the_future_it_wraps() {
        assert_eq!(within_work_send(async { 41 + 1 }).await, 42);
    }

    // ── network-driven sessions ───────────────────────────────────────────────

    #[test]
    fn a_tag_a_network_peer_wrote_to_is_network_driven_but_not_thereby_sensitive() {
        let tags = SensitiveTags::in_memory();
        assert!(!tags.is_network_driven("cody-a"));
        tags.mark_network_driven("cody-a");
        assert!(tags.is_network_driven("cody-a"));
        assert!(!tags.is_network_driven("cody-b"));
        assert!(
            !tags.tag_is_sensitive("cody-a"),
            "a network peer may keep conversing with a session it drove"
        );
        // A clone shares the registry.
        let clone = tags.clone();
        clone.mark_network_driven("cody-c");
        assert!(tags.is_network_driven("cody-c"));
    }

    // ── bounded opaque-tag memory ─────────────────────────────────────────────

    #[test]
    fn an_oversized_tag_never_ends_up_as_a_key_and_its_stand_in_is_short_and_unrelated() {
        let tags = SensitiveTags::in_memory();
        for i in 0..100 {
            let junk = format!("{i:04}{}:fred", "j".repeat(1000));
            assert!(tags.tag_is_sensitive(&junk));
            let opaque = tags.opaque_tag(&junk);
            assert!(opaque.len() <= 64, "stand-in is {} bytes", opaque.len());
            assert!(!opaque.contains("jjjj"), "{opaque}");
        }
        assert!(
            tags.ephemeral_footprint_bytes() < 100 * 256,
            "oversized tags were retained: {} bytes held",
            tags.ephemeral_footprint_bytes()
        );
    }

    #[test]
    fn ordinary_short_tags_keep_a_stable_stand_in() {
        let tags = SensitiveTags::in_memory();
        let first = tags.opaque_tag("x:fred");
        assert_eq!(first, tags.opaque_tag("x:fred"));
        assert_ne!(first, tags.opaque_tag("y:fred"));
    }

    #[test]
    fn the_total_bytes_held_for_stand_ins_stay_capped_even_with_thousands_of_mid_sized_tags() {
        let tags = SensitiveTags::in_memory();
        for i in 0..4096 {
            let mid = format!("{i:05}{}:fred", "m".repeat(190));
            let _ = tags.opaque_tag(&mid);
        }
        assert!(
            tags.ephemeral_footprint_bytes() <= 512 * 1024,
            "4096 x ~200-byte tags hold {} bytes; the total must be capped (512 KiB)",
            tags.ephemeral_footprint_bytes()
        );
    }

    // ── persistence that fails open ───────────────────────────────────────────

    fn registry_in(dir: &Path) -> PathBuf {
        registry_path_beside(&dir.join("daemon-sessions.json"))
    }

    fn sentinel_beside(registry: &Path) -> PathBuf {
        registry.with_file_name("sensitive-tags.dirty")
    }

    /// A writer that really writes while `fail_next` is 0 and fails (and counts
    /// the attempt) while it is positive; `fail_always` overrides.
    struct ScriptedDisk {
        fail_always: Arc<AtomicBool>,
        fail_next: Arc<AtomicUsize>,
        attempts: Arc<AtomicUsize>,
    }

    impl ScriptedDisk {
        fn new() -> (Self, RegistryWriter) {
            let disk = Self {
                fail_always: Arc::new(AtomicBool::new(false)),
                fail_next: Arc::new(AtomicUsize::new(0)),
                attempts: Arc::new(AtomicUsize::new(0)),
            };
            let (always, next, attempts) =
                (Arc::clone(&disk.fail_always), Arc::clone(&disk.fail_next), Arc::clone(&disk.attempts));
            let writer: RegistryWriter = Arc::new(move |path: &Path, bytes: &[u8]| {
                attempts.fetch_add(1, Ordering::SeqCst);
                if always.load(Ordering::SeqCst) {
                    return Err(std::io::Error::other("disk full"));
                }
                // Hand-rolled decrement-if-positive: `fetch_update` is renamed
                // `try_update` on newer toolchains (deprecated under -D warnings),
                // and older ones lack `try_update`, so avoid both.
                loop {
                    let n = next.load(Ordering::SeqCst);
                    if n == 0 {
                        break;
                    }
                    if next
                        .compare_exchange(n, n - 1, Ordering::SeqCst, Ordering::SeqCst)
                        .is_ok()
                    {
                        return Err(std::io::Error::other("transient"));
                    }
                }
                if let Some(dir) = path.parent() {
                    std::fs::create_dir_all(dir)?;
                }
                std::fs::write(path, bytes)
            });
            (disk, writer)
        }
        fn attempts(&self) -> usize {
            self.attempts.load(Ordering::SeqCst)
        }
    }

    #[test]
    fn a_registry_that_cannot_be_written_still_protects_the_tag_retries_a_bounded_number_of_times_and_goes_degraded_with_a_sentinel() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_in(dir.path());
        let (disk, writer) = ScriptedDisk::new();
        let tags = SensitiveTags::persisted_with_writer(path.clone(), writer);
        assert!(!tags.is_degraded(), "a registry on a healthy disk starts healthy");
        assert!(!sentinel_beside(&path).exists());

        disk.fail_always.store(true, Ordering::SeqCst);
        let before = disk.attempts();
        tags.mark_tag("cody-x");

        assert!(tags.tag_is_sensitive("cody-x"), "a failed write must not un-protect the tag in memory");
        let used = disk.attempts() - before;
        assert!((2..=5).contains(&used), "a failing write is retried a bounded number of times, used {used}");
        assert!(tags.is_degraded());
        assert!(sentinel_beside(&path).exists(), "the sentinel must record that the registry is incomplete");
    }

    #[test]
    fn a_job_registration_that_cannot_be_persisted_is_kept_in_memory_and_degrades_the_registry_too() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_in(dir.path());
        let (disk, writer) = ScriptedDisk::new();
        let tags = SensitiveTags::persisted_with_writer(path.clone(), writer);

        disk.fail_always.store(true, Ordering::SeqCst);
        tags.mark_job("job-9");

        assert!(tags.job_is_sensitive("job-9"));
        assert!(tags.is_degraded());
        assert!(sentinel_beside(&path).exists());
    }

    #[test]
    fn a_transient_write_failure_is_retried_and_leaves_the_registry_healthy_and_persisted() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_in(dir.path());
        let (disk, writer) = ScriptedDisk::new();
        let tags = SensitiveTags::persisted_with_writer(path.clone(), writer);

        disk.fail_next.store(1, Ordering::SeqCst);
        let before = disk.attempts();
        tags.mark_tag("cody-x");

        assert!(disk.attempts() - before >= 2, "the failed write must have been retried");
        assert!(!tags.is_degraded());
        assert!(!sentinel_beside(&path).exists());
        assert!(
            SensitiveTags::persisted(path).tag_is_sensitive("cody-x"),
            "the retried write must have reached the disk"
        );
    }

    #[test]
    fn a_later_successful_write_clears_the_degraded_state_and_removes_the_sentinel() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_in(dir.path());
        let (disk, writer) = ScriptedDisk::new();
        let tags = SensitiveTags::persisted_with_writer(path.clone(), writer);

        disk.fail_always.store(true, Ordering::SeqCst);
        tags.mark_tag("cody-x");
        assert!(tags.is_degraded());
        assert!(sentinel_beside(&path).exists());

        disk.fail_always.store(false, Ordering::SeqCst);
        tags.mark_tag("cody-y");

        assert!(!tags.is_degraded());
        assert!(!sentinel_beside(&path).exists(), "a healthy write must remove the sentinel");
        assert!(tags.tag_is_sensitive("cody-x") && tags.tag_is_sensitive("cody-y"));
    }

    #[test]
    fn after_a_failed_write_and_a_restart_a_resumed_session_is_sensitive_and_a_fresh_one_is_not() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_in(dir.path());
        {
            let (disk, writer) = ScriptedDisk::new();
            let tags = SensitiveTags::persisted_with_writer(path.clone(), writer);
            disk.fail_always.store(true, Ordering::SeqCst);
            tags.mark_tag("cody-x");
            assert!(tags.is_degraded());
        }
        // The registry never reached the disk; only the sentinel did.
        let _ = std::fs::remove_file(&path);
        assert!(sentinel_beside(&path).exists());

        let restarted = SensitiveTags::persisted(path.clone());
        assert!(restarted.is_degraded(), "a present sentinel means the registry may be missing entries");

        restarted.note_resumed("cody-x");
        assert!(restarted.tag_is_sensitive("cody-x"), "a resumed session of a degraded registry fails closed");
        assert!(!restarted.tag_is_sensitive("cody-fresh"), "a session that was not resumed is unaffected");
    }

    #[test]
    fn every_session_resumed_after_a_degraded_restart_is_protected_not_only_the_first() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_in(dir.path());
        std::fs::write(sentinel_beside(&path), b"dirty").unwrap();

        // The disk is healthy again, so registering the first resumed tag
        // writes fine; the registry is nevertheless still missing whatever was
        // lost before, so the next resumed session must be protected as well.
        let restarted = SensitiveTags::persisted(path);
        restarted.note_resumed("cody-a");
        restarted.note_resumed("cody-b");
        restarted.note_resumed("cody-c");
        for tag in ["cody-a", "cody-b", "cody-c"] {
            assert!(restarted.tag_is_sensitive(tag), "{tag}");
        }
    }

    #[test]
    fn a_registry_whose_probe_write_fails_at_startup_is_degraded_and_protects_resumed_sessions() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_in(dir.path());
        let (disk, writer) = ScriptedDisk::new();
        disk.fail_always.store(true, Ordering::SeqCst);

        let tags = SensitiveTags::persisted_with_writer(path, writer);

        assert!(tags.is_degraded(), "a registry that cannot be written at startup cannot be trusted");
        tags.note_resumed("cody-x");
        assert!(tags.tag_is_sensitive("cody-x"));
        assert!(!tags.tag_is_sensitive("cody-fresh"));
    }

    #[test]
    fn a_healthy_registry_restart_does_not_make_an_ordinary_resumed_session_sensitive() {
        let dir = tempfile::tempdir().unwrap();
        let path = registry_in(dir.path());
        SensitiveTags::persisted(path.clone()).mark_tag("cody-x");

        let restarted = SensitiveTags::persisted(path.clone());
        assert!(!restarted.is_degraded());
        restarted.note_resumed("cody-ordinary");

        assert!(!restarted.tag_is_sensitive("cody-ordinary"));
        assert!(restarted.tag_is_sensitive("cody-x"), "registered tags survive the restart");
        assert!(!sentinel_beside(&path).exists());
    }

    #[test]
    fn note_resumed_on_an_already_registered_tag_changes_nothing() {
        let tags = SensitiveTags::in_memory();
        tags.mark_tag("cody-x");
        tags.note_resumed("cody-x");
        assert!(tags.tag_is_sensitive("cody-x"));
        assert!(!tags.is_degraded(), "an in-memory registry is never degraded");
    }
}
