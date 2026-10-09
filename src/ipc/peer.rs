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
        }
    }

    /// A registry persisted at `path`, seeded from it when it exists.
    pub fn persisted(path: PathBuf) -> Self {
        let unreadable = |why: &dyn std::fmt::Display| {
            warn!(path = %path.display(), "sensitive-tag registry unreadable ({why}); treating every tag as sensitive");
            Registered { unreadable: true, ..Registered::default() }
        };
        let registered = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<Registered>(&bytes).unwrap_or_else(|e| unreadable(&e)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Registered::default(),
            Err(e) => unreadable(&e),
        };
        Self {
            inner: Arc::new(RwLock::new(registered)),
            path: Some(Arc::new(path)),
        }
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
        if !registered.tags.contains_key(tag) {
            registered.tags.insert(tag.to_string(), new_opaque_tag());
            self.persist(&registered);
        }
    }

    /// Register Mother job `job_id` as sensitive. Idempotent.
    pub fn mark_job(&self, job_id: &str) {
        let mut registered = self.inner.write().unwrap();
        if registered.jobs.insert(job_id.to_string()) {
            self.persist(&registered);
        }
    }

    /// The stand-in shown to network peers for a sensitive `tag`: stable for
    /// the life of the registration (or, for a tag that is sensitive without
    /// being registered, of this process) and unrelated to the tag's text.
    fn opaque_tag(&self, tag: &str) -> String {
        let mut registered = self.inner.write().unwrap();
        if let Some(opaque) = registered.tags.get(tag).or_else(|| registered.ephemeral.get(tag)) {
            return opaque.clone();
        }
        let opaque = new_opaque_tag();
        registered.ephemeral.insert(tag.to_string(), opaque.clone());
        opaque
    }

    /// Write the registry out. Called with the registry's write lock held, so
    /// concurrent registrations are serialised and the last write on disk is
    /// the latest state.
    fn persist(&self, registered: &Registered) {
        let Some(path) = &self.path else { return };
        if registered.unreadable {
            // Leave the unreadable file for the operator rather than replace
            // it with a registry that forgot everything before this run.
            return;
        }
        let json = match serde_json::to_vec(registered) {
            Ok(j) => j,
            Err(e) => {
                warn!("sensitive-tag registry: serialise failed: {e}");
                return;
            }
        };
        if let Err(e) = write_atomic(path, &json) {
            warn!(path = %path.display(), "sensitive-tag registry: persist failed: {e}");
        }
    }
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
//     `mother_resume`, `decision_answer`, `pty_spawn`/`pty_input`/`pty_kill`/…,
//     `session_spawn` (for a non-Teri/Fred agent), `close_pane`,
//     `rendered_shape`, and `session_*` verbs on non-sensitive tags.
//   * daemon → client: PTY output (`pty_*`), `mother_statusline`, and the pane
//     content / layout / notifications / decisions / activity / transcripts /
//     Perri state of every focus that is NOT a sensitive tag. Pane content of an ordinary dynamic focus can
//     therefore still show whatever its agent put there.
//   * a Teri/Fred-derived focus is only recognised when it is a built-in, was
//     created through `WorkSend` or `create_focus` with seeded context, or runs
//     the `fred`/`teri` agent. Text an agent pastes into some other focus, or
//     a Mother job started from a shell, is not tracked.
//
// What this module DOES guarantee for network peers: nothing Teri/Fred-derived
// that the daemon can identify (the four cases above) is delivered or driven
// through any frame family, on the replay, broadcast and targeted paths.

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

/// Must a network peer's `msg` be refused? (Either family above.)
pub fn refuse_for_network(msg: &ClientMsg, tags: &SensitiveTags) -> bool {
    is_sensitive_client_msg(msg) || targets_sensitive_session(msg, tags)
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
        assert!(!refuse_for_network(&spawn("anything", "cody"), &tags));
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
}
