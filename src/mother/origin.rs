//! Who queued a Mother job, as the daemon vouches for it.
//!
//! Mother stores a *claim* (`origin.focus`, `origin.session`) that any process
//! of the user can write. The daemon is the authority for what a job's origin
//! *is*, and keeps its own record of that:
//!
//! * [`SessionHistory`] (`~/.nostromo/focus-session-history.json`): every
//!   Claude session id the daemon spawned for each focus tag, newest 64 per
//!   tag. A shell claim `{focus F, session S}` is verified when `S` is in F's
//!   history.
//! * [`OriginBook`] (`~/.nostromo/mother-origins.json`): per job id, the kind
//!   of origin decided **once**, and the optional `notify` level. An MCP or app
//!   enqueue is stamped from the connection's own identity; every other job is
//!   evaluated from its claim the first time the daemon sees it. The only
//!   change ever made to an entry is an upgrade (`unknown`/`unverified` to a
//!   verified stamp); a `focus` or `you` entry is never changed back.
//!
//! [`OriginBook::annotate`] stamps each job of the feed with a
//! [`JobAnnotation`] (`MotherJob.nostromo`), which is the only face the claim
//! has on the wire: the raw claim and the session id are never serialised.
//!
//! Verification compares the claimed session id with the daemon's per-focus
//! session history. It stops accidental and casual mis-claims, not a determined
//! process of the same user (plan index Q4).
//!
//! Nothing here logs or audits a title, a focus name, a session id or a plan
//! path: ids, tags and fixed words only.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use super::audit::{MotherAudit, MotherAuditEvent};
use super::{validate_job_id, MotherJob};
use crate::data::work::untrusted::one_line;
use crate::ipc::protocol::FocusMeta;

/// Longest focus name kept or shown.
pub const NAME_MAX_CHARS: usize = 120;
/// What a network peer sees in place of a sensitive focus's name.
pub const SENSITIVE_NAME: &str = "a sensitive focus";

const HISTORY_PER_TAG: usize = 64;
const HISTORY_MAX_AGE_MS: i64 = 90 * DAY_MS;
const BOOK_ABSENT_MAX_AGE_MS: i64 = 30 * DAY_MS;
const DAY_MS: i64 = 24 * 60 * 60 * 1000;
const SESSION_PREFIX_CHARS: usize = 8;
const MAX_TAG_CHARS: usize = 80;

// ── wire types ───────────────────────────────────────────────────────────────

/// What kind of origin a job has (`nostromo.origin.kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OriginKind {
    /// A focus queued it and the daemon vouches for that (open or closed is
    /// decided at display time).
    Focus,
    /// A record claims a focus the daemon cannot vouch for.
    Unverified,
    /// The user queued it in the app (Send to agent).
    You,
    /// The record makes no claim.
    Unknown,
}

/// How an origin came to be known.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Via {
    /// Stamped from an MCP connection's own identity.
    Mcp,
    /// A claim in the job record, checked against the session history.
    Shell,
    /// The app's Send to agent.
    App,
}

/// How a focus is told about a job (`mother.enqueue_job`'s `notify`): it only
/// ever lowers what the focus setting allows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotifyLevel {
    Wake,
    Quiet,
    Off,
}

impl NotifyLevel {
    /// `wake`, `quiet` or `off`; anything else is `None`.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "wake" => Some(Self::Wake),
            "quiet" => Some(Self::Quiet),
            "off" => Some(Self::Off),
            _ => None,
        }
    }
}

/// `MotherJob.nostromo`: what the daemon knows about a job that Mother does not.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct JobAnnotation {
    pub origin: OriginView,
    /// The job's own notify level, if the enqueue gave one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notify: Option<NotifyLevel>,
    /// Placeholder: the notice state (MF2a gives it a type). Removed for a
    /// network peer when the origin focus is sensitive.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<serde_json::Value>,
    /// The focus was sensitive when it queued the job (see
    /// [`OriginEntry::sensitive`]). Never serialised: the daemon uses it to
    /// withhold the names from a network peer after the cause has lapsed.
    #[serde(skip)]
    pub origin_was_sensitive: bool,
}

/// The origin of a job as shown (§W of the plan index).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OriginView {
    pub kind: OriginKind,
    /// The focus tag: the verified one, or the claimed one for `unverified`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_tag: Option<String>,
    /// The focus's name when the origin was decided.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name_snapshot: Option<String>,
    /// The focus's current name, from the registry the Mac pushed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_name: Option<String>,
    /// `true` once the daemon has seen a registry push and the tag is not in
    /// it. Absent while no registry has been pushed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub closed: Option<bool>,
    /// The first 8 characters of the originating Claude session id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_prefix: Option<String>,
}

impl Default for OriginView {
    fn default() -> Self {
        Self {
            kind: OriginKind::Unknown,
            focus_tag: None,
            name_snapshot: None,
            focus_name: None,
            closed: None,
            session_prefix: None,
        }
    }
}

impl JobAnnotation {
    /// Trim what a network peer may see: no focus tag, no session prefix, no
    /// notice. When the origin focus is sensitive (`tag_is_sensitive`, asked
    /// about the tag before it is removed) or was when it queued the job, both
    /// names become [`SENSITIVE_NAME`].
    pub fn redact_for_network(&mut self, tag_is_sensitive: impl Fn(&str) -> bool) {
        let sensitive = self.origin_was_sensitive
            || self
                .origin
                .focus_tag
                .as_deref()
                .is_some_and(tag_is_sensitive);
        self.origin.focus_tag = None;
        self.origin.session_prefix = None;
        if sensitive {
            self.origin.focus_name = Some(SENSITIVE_NAME.to_owned());
            self.origin.name_snapshot = Some(SENSITIVE_NAME.to_owned());
            self.notice = None;
        }
    }
}

// ── session history ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct SessionSeen {
    sid: String,
    first_seen_ms: i64,
    /// Refreshed every time the daemon spawns this session again (a resume),
    /// so a long-lived focus's current session is never aged out.
    #[serde(default)]
    last_seen_ms: i64,
}

impl SessionSeen {
    fn last_seen(&self) -> i64 {
        self.last_seen_ms.max(self.first_seen_ms)
    }
}

/// Every Claude session id the daemon has spawned for each focus tag.
///
/// Cheap to clone; clones share the history. Departed tags are kept (old jobs
/// may be verified later); entries not seen for 90 days are dropped on write.
#[derive(Clone)]
pub struct SessionHistory {
    inner: Arc<Mutex<HistoryState>>,
}

struct HistoryState {
    path: Option<PathBuf>,
    tags: BTreeMap<String, Vec<SessionSeen>>,
}

impl SessionHistory {
    /// `~/.nostromo/focus-session-history.json`'s sibling of `store_path`.
    pub fn path_beside(store_path: &Path) -> PathBuf {
        store_path.with_file_name("focus-session-history.json")
    }

    /// The history stored at `path`: empty when it is missing, or when it
    /// cannot be read (see [`load_json`]: the bad file is kept as a `.bak`
    /// before anything can write over it).
    pub fn open(path: PathBuf) -> Self {
        let tags = load_json(&path);
        Self {
            inner: Arc::new(Mutex::new(HistoryState {
                path: Some(path),
                tags,
            })),
        }
    }

    /// A history that is never written to disk.
    pub fn in_memory() -> Self {
        Self {
            inner: Arc::new(Mutex::new(HistoryState {
                path: None,
                tags: BTreeMap::new(),
            })),
        }
    }

    /// Note that the daemon is spawning session `sid` for `tag` now.
    pub fn record(&self, tag: &str, sid: &str) {
        self.record_at(tag, sid, now_ms());
    }

    /// [`SessionHistory::record`] with the time given.
    pub fn record_at(&self, tag: &str, sid: &str, now_ms: i64) {
        if tag.is_empty() || sid.is_empty() {
            return;
        }
        let mut state = lock(&self.inner);
        let seen = state.tags.entry(tag.to_owned()).or_default();
        match seen.iter().position(|s| s.sid == sid) {
            Some(i) => {
                let mut existing = seen.remove(i);
                existing.last_seen_ms = now_ms;
                seen.push(existing);
            }
            None => seen.push(SessionSeen {
                sid: sid.to_owned(),
                first_seen_ms: now_ms,
                last_seen_ms: now_ms,
            }),
        }
        if seen.len() > HISTORY_PER_TAG {
            let excess = seen.len() - HISTORY_PER_TAG;
            seen.drain(..excess);
        }
        for seen in state.tags.values_mut() {
            seen.retain(|s| now_ms - s.last_seen() <= HISTORY_MAX_AGE_MS);
        }
        state.tags.retain(|_, seen| !seen.is_empty());
        if let Some(path) = &state.path {
            if write_private(path, &state.tags).is_err() {
                tracing::warn!("focus session history could not be written");
            }
        }
    }

    /// Has the daemon spawned session `sid` for `tag`?
    pub fn contains(&self, tag: &str, sid: &str) -> bool {
        !sid.is_empty()
            && lock(&self.inner)
                .tags
                .get(tag)
                .is_some_and(|seen| seen.iter().any(|s| s.sid == sid))
    }

    /// The one tag the daemon spawned session `sid` for. `None` when no tag
    /// has it, or when more than one does (a session id belongs to one focus;
    /// an ambiguous one vouches for nobody).
    pub fn tag_of(&self, sid: &str) -> Option<String> {
        if sid.is_empty() {
            return None;
        }
        let state = lock(&self.inner);
        let mut owners = state
            .tags
            .iter()
            .filter(|(_, seen)| seen.iter().any(|s| s.sid == sid))
            .map(|(tag, _)| tag);
        match (owners.next(), owners.next()) {
            (Some(tag), None) => Some(tag.clone()),
            _ => None,
        }
    }
}

// ── the origin book ──────────────────────────────────────────────────────────

/// One job's recorded origin.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OriginEntry {
    pub kind: OriginKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name_snapshot: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_prefix: Option<String>,
    pub via: Via,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notify: Option<NotifyLevel>,
    /// The focus was sensitive (registered, a Teri/Fred session, or held
    /// sensitive while it followed a remote shell) when it queued the job. A
    /// hold lapses, so the name recorded then must stay withheld from a
    /// network peer after it does.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub sensitive: bool,
    pub evaluated_at_ms: i64,
    /// When the job was last in the feed; entries absent for 30 days go.
    #[serde(default)]
    last_seen_ms: i64,
}

/// The focus an MCP call comes from, as far as stamping a job needs it
/// (`SessionManager::origin_caller`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OriginCaller {
    pub tag: String,
    /// The focus's registry name now, unsanitised.
    pub name: Option<String>,
    /// The Claude session id the focus is running.
    pub session: Option<String>,
    /// The focus carries Teri/Fred-derived content: its name is not written
    /// into Mother's record or argv (the daemon's own book keeps it, and a
    /// network peer never sees it).
    pub sensitive: bool,
}

impl OriginCaller {
    /// The `--origin-session` / `--origin-focus-name` values: the session id
    /// as is, the name sanitised and not starting with `-`; no name at all for
    /// a sensitive focus.
    pub fn flag_values(&self) -> (Option<String>, Option<String>) {
        let name = self
            .name
            .as_deref()
            .filter(|_| !self.sensitive)
            .and_then(clean_name)
            .map(|n| n.trim_start_matches('-').trim_start().to_owned())
            .filter(|n| !n.is_empty());
        let session = self
            .session
            .clone()
            .filter(|s| !s.is_empty() && !s.starts_with('-'));
        (session, name)
    }

    /// The stamp this caller's enqueue records.
    pub fn stamp(&self, via: Via, notify: Option<NotifyLevel>) -> Stamp {
        Stamp {
            sensitive: self.sensitive,
            ..Stamp::focus(
                &self.tag,
                self.name.as_deref(),
                self.session.as_deref(),
                via,
                notify,
            )
        }
    }
}

/// What an MCP or app enqueue records.
#[derive(Debug, Clone, PartialEq)]
pub struct Stamp {
    kind: OriginKind,
    focus_tag: Option<String>,
    name_snapshot: Option<String>,
    session_prefix: Option<String>,
    via: Via,
    notify: Option<NotifyLevel>,
    sensitive: bool,
}

impl Stamp {
    /// A focus queued the job: `tag` is the caller's own tag, `name` the focus's
    /// name now, `session` its current Claude session id.
    pub fn focus(
        tag: &str,
        name: Option<&str>,
        session: Option<&str>,
        via: Via,
        notify: Option<NotifyLevel>,
    ) -> Self {
        Self {
            kind: OriginKind::Focus,
            focus_tag: Some(tag.to_owned()),
            name_snapshot: name.and_then(clean_name),
            session_prefix: session.and_then(session_prefix),
            via,
            notify,
            sensitive: false,
        }
    }

    /// The user queued the job in the app.
    pub fn you(notify: Option<NotifyLevel>) -> Self {
        Self {
            kind: OriginKind::You,
            focus_tag: None,
            name_snapshot: None,
            session_prefix: None,
            via: Via::App,
            notify,
            sensitive: false,
        }
    }
}

/// The Mac-pushed focus registry, as far as origins need it.
#[derive(Default)]
struct FocusDirectory {
    /// A non-empty registry has been pushed since the daemon started.
    pushed: bool,
    /// Every registered tag with its (unsanitised) display name.
    names: HashMap<String, String>,
    /// Tags a push lacked that may still exist: one the session manager is
    /// waiting for a second push to confirm gone (departures are debounced), or
    /// one the daemon created that the Mac has not acknowledged yet.
    retained: HashSet<String>,
}

impl FocusDirectory {
    fn name_of(&self, tag: &str) -> Option<String> {
        self.names.get(tag).and_then(|n| clean_name(n))
    }

    /// Is `tag` in the registry, or in the grace the session manager gives a
    /// tag missing from one push?
    fn may_exist(&self, tag: &str) -> bool {
        self.names.contains_key(tag) || self.retained.contains(tag)
    }
}

struct BookState {
    path: Option<PathBuf>,
    entries: BTreeMap<String, OriginEntry>,
    focuses: FocusDirectory,
    /// Enqueues in flight (see [`OriginBook::begin_enqueue`]).
    enqueues_in_flight: usize,
}

/// Held by an enqueue from `mother add` until its job is stamped: a job the
/// poller sees in that gap is not decided yet.
pub struct EnqueueGuard {
    state: Arc<Mutex<BookState>>,
}

impl Drop for EnqueueGuard {
    fn drop(&mut self) {
        let mut state = lock(&self.state);
        state.enqueues_in_flight = state.enqueues_in_flight.saturating_sub(1);
    }
}

/// The daemon's record of every job's origin. Cheap to clone; clones share it.
#[derive(Clone)]
pub struct OriginBook {
    state: Arc<Mutex<BookState>>,
    history: SessionHistory,
    audit: MotherAudit,
}

impl OriginBook {
    /// `~/.nostromo/mother-origins.json`'s sibling of `store_path`.
    pub fn path_beside(store_path: &Path) -> PathBuf {
        store_path.with_file_name("mother-origins.json")
    }

    /// The book stored at `path`: empty when it is missing, or when it cannot
    /// be read (see [`load_json`]: the bad file is kept as a `.bak` before
    /// anything can write over it).
    pub fn open(path: PathBuf, history: SessionHistory, audit: MotherAudit) -> Self {
        let entries = load_json(&path);
        Self::with_state(Some(path), entries, history, audit)
    }

    /// A book that is never written to disk.
    pub fn in_memory(history: SessionHistory, audit: MotherAudit) -> Self {
        Self::with_state(None, BTreeMap::new(), history, audit)
    }

    fn with_state(
        path: Option<PathBuf>,
        entries: BTreeMap<String, OriginEntry>,
        history: SessionHistory,
        audit: MotherAudit,
    ) -> Self {
        Self {
            state: Arc::new(Mutex::new(BookState {
                path,
                entries,
                focuses: FocusDirectory::default(),
                enqueues_in_flight: 0,
            })),
            history,
            audit,
        }
    }

    /// The session history claims are checked against.
    pub fn history(&self) -> &SessionHistory {
        &self.history
    }

    /// The recorded origin of `job_id`, if one was decided.
    pub fn entry(&self, job_id: &str) -> Option<OriginEntry> {
        lock(&self.state).entries.get(job_id).cloned()
    }

    /// The registry the Mac pushed. Only a non-empty push is evidence that a
    /// missing tag was closed (an empty one is what a client sends before it
    /// has loaded anything).
    pub fn note_registry_push(&self, focuses: &[FocusMeta]) {
        self.note_registry_push_retaining(focuses, HashSet::new());
    }

    /// [`OriginBook::note_registry_push`] for a manager that debounces
    /// departures: a tag in `retained` is absent from this push but has not
    /// been confirmed gone (a second push must agree), so it is not `closed`.
    pub fn note_registry_push_retaining(&self, focuses: &[FocusMeta], retained: HashSet<String>) {
        let mut state = lock(&self.state);
        state.focuses = FocusDirectory {
            pushed: !focuses.is_empty(),
            names: names_of(focuses),
            retained,
        };
    }

    /// The registry changed without a push (the daemon created a focus): names
    /// follow, but this is no evidence about which focuses are closed.
    pub fn note_registry_update(&self, focuses: &[FocusMeta]) {
        lock(&self.state).focuses.names = names_of(focuses);
    }

    /// An enqueue through `mother add` is about to start: take this before it
    /// and drop it after [`OriginBook::stamp`]. Mother lists the new job before
    /// the daemon has stamped it, so while a guard lives a job the book has not
    /// seen is shown without an origin and **not recorded or audited**: the
    /// next poll decides it, from the stamp. (Without this a poll in the gap
    /// could audit `job_origin_unverified` for the daemon's own enqueue.)
    pub fn begin_enqueue(&self) -> EnqueueGuard {
        lock(&self.state).enqueues_in_flight += 1;
        EnqueueGuard {
            state: Arc::clone(&self.state),
        }
    }

    /// Record who queued `job_id`, from a connection's own identity. Returns
    /// whether the stamp was written.
    ///
    /// Upgrades only: it replaces nothing but an `unknown` or `unverified`
    /// entry. A `focus` or `you` entry is never overwritten (an enqueue that
    /// lost a race with the poller's evaluation can still add its `notify`).
    pub fn stamp(&self, job_id: &str, stamp: Stamp) -> bool {
        if validate_job_id(job_id).is_err() {
            return false;
        }
        let now = now_ms();
        let audit = {
            let mut state = lock(&self.state);
            let notify_only = match state.entries.get_mut(job_id) {
                Some(existing) if matches!(existing.kind, OriginKind::Focus | OriginKind::You) => {
                    if existing.notify.is_none()
                        && stamp.notify.is_some()
                        && existing.focus_tag == stamp.focus_tag
                    {
                        existing.notify = stamp.notify;
                        true
                    } else {
                        return false;
                    }
                }
                _ => false,
            };
            if notify_only {
                state.persist();
                return false;
            }
            let event = MotherAuditEvent::JobOriginStamped {
                job: job_id.to_owned(),
                focus: stamp.focus_tag.clone(),
                via: stamp.via,
            };
            state.entries.insert(
                job_id.to_owned(),
                OriginEntry {
                    kind: stamp.kind,
                    focus_tag: stamp.focus_tag,
                    name_snapshot: stamp.name_snapshot,
                    session_prefix: stamp.session_prefix,
                    via: stamp.via,
                    notify: stamp.notify,
                    sensitive: stamp.sensitive,
                    evaluated_at_ms: now,
                    last_seen_ms: now,
                },
            );
            state.persist();
            event
        };
        self.audit.record(&audit);
        true
    }

    /// Give every job its `nostromo` annotation, deciding the origin of any job
    /// the book has not seen yet (once, from its claim and the session
    /// history), and forget jobs absent from the feed for 30 days.
    pub fn annotate(&self, jobs: &mut [MotherJob]) {
        let now = now_ms();
        let mut unverified = Vec::new();
        {
            let mut state = lock(&self.state);
            let mut dirty = false;
            for job in jobs.iter_mut() {
                let entry = match state.entries.get_mut(&job.id) {
                    Some(entry) => {
                        entry.last_seen_ms = now;
                        entry.clone()
                    }
                    None => {
                        let entry = self.evaluate(job, &state.focuses, now);
                        if state.enqueues_in_flight > 0
                            && matches!(entry.kind, OriginKind::Unverified | OriginKind::Unknown)
                        {
                            // Maybe the daemon's own enqueue, not stamped yet:
                            // show it undecided, leave no entry and no audit.
                            job.nostromo = Some(JobAnnotation::default());
                            continue;
                        }
                        if entry.kind == OriginKind::Unverified && validate_job_id(&job.id).is_ok()
                        {
                            unverified.push(MotherAuditEvent::JobOriginUnverified {
                                job: job.id.clone(),
                                claimed_focus: entry
                                    .focus_tag
                                    .clone()
                                    .unwrap_or_else(|| "invalid".to_owned()),
                            });
                        }
                        state.entries.insert(job.id.clone(), entry.clone());
                        dirty = true;
                        entry
                    }
                };
                job.nostromo = Some(JobAnnotation {
                    origin: view_of(&entry, &state.focuses),
                    notify: entry.notify,
                    notice: None,
                    origin_was_sensitive: entry.sensitive,
                });
            }
            let live: HashSet<&str> = jobs.iter().map(|j| j.id.as_str()).collect();
            let before = state.entries.len();
            state.entries.retain(|id, e| {
                live.contains(id.as_str()) || now - e.last_seen_ms <= BOOK_ABSENT_MAX_AGE_MS
            });
            dirty |= state.entries.len() != before;
            if dirty {
                state.persist();
            }
        }
        for event in &unverified {
            self.audit.record(event);
        }
    }

    /// Decide the origin of a job the book has not seen, from its claim.
    fn evaluate(&self, job: &MotherJob, focuses: &FocusDirectory, now: i64) -> OriginEntry {
        let origin = job.origin.as_ref();
        let claim = origin
            .and_then(|o| o.focus.as_deref())
            .map(str::trim)
            .filter(|f| !f.is_empty());
        let entry = |kind, focus_tag, name_snapshot, session_prefix| OriginEntry {
            kind,
            focus_tag,
            name_snapshot,
            session_prefix,
            via: Via::Shell,
            notify: None,
            sensitive: false,
            evaluated_at_ms: now,
            last_seen_ms: now,
        };
        let session = origin
            .and_then(|o| o.session.as_deref())
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let Some(claimed) = claim else {
            // No focus claimed. A session id alone (an older `mother`, or the
            // daemon's own enqueue without `--origin-focus`) still says which
            // focus it is when exactly one focus's history has it.
            if let Some((sid, tag)) = session.and_then(|sid| Some((sid, self.history.tag_of(sid)?)))
            {
                let name = focuses.name_of(&tag);
                return entry(OriginKind::Focus, Some(tag), name, session_prefix(sid));
            }
            return entry(OriginKind::Unknown, None, None, None);
        };
        let tag = is_tag_like(claimed).then(|| claimed.to_owned());
        match (tag, session) {
            (Some(tag), Some(sid)) if self.history.contains(&tag, sid) => {
                let name = focuses.name_of(&tag).or_else(|| claimed_name(origin));
                entry(OriginKind::Focus, Some(tag), name, session_prefix(sid))
            }
            // Only what was claimed: the registry's name for a tag nobody
            // vouched for would lend the claim a real focus's face.
            (tag, _) => entry(OriginKind::Unverified, tag, claimed_name(origin), None),
        }
    }
}

impl BookState {
    fn persist(&self) {
        if let Some(path) = &self.path {
            if write_private(path, &self.entries).is_err() {
                tracing::warn!("mother origin book could not be written");
            }
        }
    }
}

fn claimed_name(origin: Option<&crate::mother::MotherJobOrigin>) -> Option<String> {
    origin
        .and_then(|o| o.focus_name.as_deref())
        .and_then(clean_name)
}

fn names_of(focuses: &[FocusMeta]) -> HashMap<String, String> {
    focuses
        .iter()
        .map(|f| (f.tag.clone(), f.display_name.clone()))
        .collect()
}

fn view_of(entry: &OriginEntry, focuses: &FocusDirectory) -> OriginView {
    let tag = entry.focus_tag.as_deref();
    // The registry speaks only for a focus the daemon vouched for; an
    // unverified claim shows what was claimed (its snapshot), flagged by kind.
    let focus_name = tag
        .filter(|_| entry.kind == OriginKind::Focus)
        .and_then(|t| focuses.name_of(t));
    let closed = match tag {
        Some(t) if entry.kind == OriginKind::Focus && focuses.pushed => Some(!focuses.may_exist(t)),
        _ => None,
    };
    OriginView {
        kind: entry.kind,
        focus_tag: entry.focus_tag.clone(),
        name_snapshot: entry.name_snapshot.clone(),
        focus_name,
        closed,
        session_prefix: entry.session_prefix.clone(),
    }
}

// ── small helpers ────────────────────────────────────────────────────────────

/// A focus name safe to store and show: one line, no invisible characters,
/// at most [`NAME_MAX_CHARS`]. `None` when nothing is left.
pub fn clean_name(raw: &str) -> Option<String> {
    let name = one_line(raw, NAME_MAX_CHARS);
    (!name.is_empty()).then_some(name)
}

/// The first 8 characters of a session id.
pub fn session_prefix(sid: &str) -> Option<String> {
    let prefix: String = sid.trim().chars().take(SESSION_PREFIX_CHARS).collect();
    (!prefix.is_empty()).then_some(prefix)
}

/// Does `s` look like a focus tag (`claudia-C9D6B773`, `teri:fred`)? A claim
/// that does not never reaches the audit file or the wire.
fn is_tag_like(s: &str) -> bool {
    !s.is_empty()
        && s.chars().count() <= MAX_TAG_CHARS
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | ':' | '.'))
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Read the JSON file at `path`. A missing file is an empty value. A file that
/// exists but cannot be read or parsed is **never silently replaced**: the next
/// write would overwrite it, so its bytes are first copied to `<file>.bak` (or
/// `<file>.bak.<ms>` when a `.bak` already exists) and a warning says so. The
/// warning carries the path and the byte count, never a byte of the content
/// (it holds session ids and focus names).
fn load_json<T: serde::de::DeserializeOwned + Default>(path: &Path) -> T {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return T::default(),
        Err(e) => {
            tracing::warn!(
                path = %path.display(),
                error_kind = ?e.kind(),
                "a Mother origin file could not be read; starting empty"
            );
            keep_backup(path);
            return T::default();
        }
    };
    match serde_json::from_slice(&bytes) {
        Ok(value) => value,
        Err(_) => {
            let backup = keep_backup(path);
            tracing::warn!(
                path = %path.display(),
                bytes = bytes.len(),
                backed_up = backup.is_some(),
                "a Mother origin file could not be parsed; starting empty (the file is kept as a backup)"
            );
            T::default()
        }
    }
}

/// How many `<file>.bak.<ms>` copies stay beside a file (the plain `.bak`, the
/// first one kept, is not counted and never goes).
const NUMBERED_BACKUPS_KEPT: usize = 3;

/// Copy `path` to a `.bak` beside it that nothing overwrites. `None` when the
/// copy failed.
///
/// A file that stays corrupt across restarts (nothing writes it in between)
/// is the same bytes every time: when a `.bak` or a numbered copy already holds
/// them, that copy is the answer and nothing new is written. Otherwise a
/// numbered copy is added, and all but the newest
/// [`NUMBERED_BACKUPS_KEPT`] numbered copies are removed (each holds session
/// ids, so they must not pile up).
fn keep_backup(path: &Path) -> Option<PathBuf> {
    let name = path.file_name()?.to_string_lossy().into_owned();
    let plain = path.with_file_name(format!("{name}.bak"));
    let numbered = numbered_backups(path, &name);
    if let Ok(bytes) = std::fs::read(path) {
        let same = |p: &Path| std::fs::read(p).is_ok_and(|b| b == bytes);
        if let Some(existing) = std::iter::once(&plain)
            .chain(numbered.iter().map(|(_, p)| p))
            .find(|p| p.exists() && same(p))
        {
            return Some(existing.clone());
        }
    }
    let backup = if plain.exists() {
        path.with_file_name(format!("{name}.bak.{}", now_ms()))
    } else {
        plain
    };
    std::fs::copy(path, &backup).ok()?;
    // Oldest first; the copy just made is the newest.
    let mut all = numbered_backups(path, &name);
    let excess = all.len().saturating_sub(NUMBERED_BACKUPS_KEPT);
    for (_, old) in all.drain(..excess) {
        if old != backup {
            let _ = std::fs::remove_file(old);
        }
    }
    Some(backup)
}

/// The `<name>.bak.<ms>` files beside `path`, oldest first.
fn numbered_backups(path: &Path, name: &str) -> Vec<(i64, PathBuf)> {
    let prefix = format!("{name}.bak.");
    let Ok(dir) = std::fs::read_dir(path.parent().unwrap_or_else(|| Path::new("."))) else {
        return Vec::new();
    };
    let mut found: Vec<(i64, PathBuf)> = dir
        .filter_map(Result::ok)
        .filter_map(|e| {
            let file = e.file_name().to_string_lossy().into_owned();
            let ms = file.strip_prefix(&prefix)?.parse::<i64>().ok()?;
            Some((ms, e.path()))
        })
        .collect();
    found.sort();
    found
}

/// Write `value` as JSON to `path`, atomically (a temp file in the same
/// directory, renamed over it), with the file mode `0600`.
fn write_private<T: Serialize>(path: &Path, value: &T) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);

    let bytes = serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?;
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(dir)?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = dir.join(format!(
        ".{name}.{}.{}.tmp",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .and_then(|mut f| f.write_all(&bytes).and_then(|()| f.sync_all()))
        .and_then(|()| std::fs::rename(&tmp, path));
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

// ── does `mother add` take --origin-focus? ───────────────────────────────────

/// How long a probe of `mother add --help` may run.
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);
/// While the answer is "no", ask again at most this often.
const REPROBE_AFTER: Duration = Duration::from_secs(60 * 60);

static PROBES: OnceLock<Mutex<HashMap<String, (bool, Instant)>>> = OnceLock::new();

/// Does the `mother` binary (`MOTHER_BIN`) accept `--origin-focus` and
/// `--origin-focus-name` on `add`? Asked once by running `mother add --help`
/// and looking for the literal flag; a yes is kept for the life of the daemon,
/// a no is asked again after an hour (Mother may have been updated).
pub async fn supports_origin_focus() -> bool {
    let bin = super::mother_bin();
    let cache = PROBES.get_or_init(Default::default);
    let cached = lock(cache).get(&bin).copied();
    if !reprobe_due(cached, Instant::now()) {
        return cached.is_some_and(|(supported, _)| supported);
    }
    let supported = probe_help(super::mother_command(), PROBE_TIMEOUT).await;
    lock(cache).insert(bin, (supported, Instant::now()));
    supported
}

/// Must the probe run again, given the cached answer?
fn reprobe_due(cached: Option<(bool, Instant)>, now: Instant) -> bool {
    match cached {
        None => true,
        Some((true, _)) => false,
        Some((false, at)) => now.saturating_duration_since(at) >= REPROBE_AFTER,
    }
}

/// Run `cmd add --help` for at most `limit`. `cmd` must kill its child when
/// dropped ([`super::mother_command`] does): a timeout drops the future that
/// owns the child, so a hung `mother` is killed, not left running.
async fn probe_help(mut cmd: tokio::process::Command, limit: Duration) -> bool {
    cmd.args(["add", "--help"]);
    let Ok(Ok(out)) = tokio::time::timeout(limit, cmd.output()).await else {
        return false;
    };
    // An old `mother` rejects `--help` as an unknown flag: whatever it prints
    // does not name the flag, so the answer is no whatever the exit status.
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    text.contains("--origin-focus")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mother::MotherJobOrigin;

    fn job(id: &str, origin: Option<MotherJobOrigin>) -> MotherJob {
        MotherJob {
            id: id.into(),
            state: "queued".into(),
            origin,
            ..Default::default()
        }
    }

    fn claim(focus: &str, session: &str) -> MotherJobOrigin {
        MotherJobOrigin {
            focus: Some(focus.into()),
            session: Some(session.into()),
            ..Default::default()
        }
    }

    fn book() -> OriginBook {
        OriginBook::in_memory(SessionHistory::in_memory(), MotherAudit::disabled())
    }

    fn focus_meta(tag: &str, name: &str) -> FocusMeta {
        FocusMeta {
            tag: tag.into(),
            display_name: name.into(),
            agent_name: "claudia".into(),
            project_name: None,
            org: None,
            is_built_in: false,
            session_summary: None,
            label: None,
            project_path: None,
            select_for_client: None,
            initial_model: None,
            initial_effort: None,
        }
    }

    #[test]
    fn a_claim_with_a_session_in_the_history_is_verified_once_and_stays() {
        let b = book();
        b.history().record("claudia-1", "sid-aaaaaaaa-1");
        let mut jobs = vec![job("j1", Some(claim("claudia-1", "sid-aaaaaaaa-1")))];
        b.annotate(&mut jobs);
        let o = &jobs[0].nostromo.as_ref().unwrap().origin;
        assert_eq!(o.kind, OriginKind::Focus);
        assert_eq!(o.focus_tag.as_deref(), Some("claudia-1"));
        assert_eq!(o.session_prefix.as_deref(), Some("sid-aaaa"));
        // The history later loses nothing, and the entry is frozen.
        assert_eq!(b.entry("j1").unwrap().via, Via::Shell);
    }

    #[test]
    fn a_claim_with_another_or_an_empty_session_is_unverified_and_stays() {
        let b = book();
        b.history().record("claudia-1", "real");
        for (id, sid) in [("j1", "forged"), ("j2", "")] {
            let mut jobs = vec![job(id, Some(claim("claudia-1", sid)))];
            b.annotate(&mut jobs);
            assert_eq!(
                jobs[0].nostromo.as_ref().unwrap().origin.kind,
                OriginKind::Unverified
            );
        }
        // A later poll with the session now in the history does not upgrade it.
        b.history().record("claudia-1", "forged");
        let mut jobs = vec![job("j1", Some(claim("claudia-1", "forged")))];
        b.annotate(&mut jobs);
        assert_eq!(
            jobs[0].nostromo.as_ref().unwrap().origin.kind,
            OriginKind::Unverified
        );
    }

    #[test]
    fn a_record_without_a_claim_is_unknown() {
        let b = book();
        let mut jobs = vec![job("j1", None), job("j2", Some(MotherJobOrigin::default()))];
        b.annotate(&mut jobs);
        for j in &jobs {
            assert_eq!(
                j.nostromo.as_ref().unwrap().origin.kind,
                OriginKind::Unknown
            );
        }
    }

    #[test]
    fn a_stamp_upgrades_unknown_and_unverified_but_nothing_overwrites_a_verified_one() {
        let b = book();
        let mut jobs = vec![job("u", None), job("v", Some(claim("f", "x")))];
        b.annotate(&mut jobs);
        for id in ["u", "v"] {
            assert!(b.stamp(
                id,
                Stamp::focus("f", Some("F"), Some("sid12345678"), Via::Mcp, None)
            ));
            assert_eq!(b.entry(id).unwrap().kind, OriginKind::Focus);
        }
        // Neither another focus nor "you" replaces a focus.
        assert!(!b.stamp("u", Stamp::focus("other", None, None, Via::Mcp, None)));
        assert!(!b.stamp("u", Stamp::you(None)));
        assert_eq!(b.entry("u").unwrap().focus_tag.as_deref(), Some("f"));
        // And "you" is not replaced by a focus.
        assert!(b.stamp("y", Stamp::you(None)));
        assert!(!b.stamp("y", Stamp::focus("f", None, None, Via::Mcp, None)));
        assert_eq!(b.entry("y").unwrap().kind, OriginKind::You);
    }

    #[test]
    fn a_stamp_that_lost_the_race_to_a_shell_verification_still_adds_its_notify() {
        let b = book();
        b.history().record("f", "sid");
        let mut jobs = vec![job("j", Some(claim("f", "sid")))];
        b.annotate(&mut jobs);
        assert!(!b.stamp(
            "j",
            Stamp::focus("f", None, None, Via::Mcp, Some(NotifyLevel::Quiet))
        ));
        let e = b.entry("j").unwrap();
        assert_eq!((e.via, e.notify), (Via::Shell, Some(NotifyLevel::Quiet)));
    }

    #[test]
    fn closed_follows_the_registry_only_after_a_push() {
        let b = book();
        b.stamp(
            "j",
            Stamp::focus("gone", Some("Old name"), None, Via::Mcp, None),
        );
        let origin = |b: &OriginBook| {
            let mut jobs = vec![job("j", None)];
            b.annotate(&mut jobs);
            jobs[0].nostromo.clone().unwrap().origin
        };
        assert_eq!(origin(&b).closed, None);
        b.note_registry_update(&[focus_meta("other", "Other")]);
        assert_eq!(origin(&b).closed, None, "an update is no evidence");
        b.note_registry_push(&[focus_meta("other", "Other")]);
        let o = origin(&b);
        assert_eq!(o.closed, Some(true));
        assert_eq!(o.focus_name, None);
        assert_eq!(o.name_snapshot.as_deref(), Some("Old name"));
        b.note_registry_push(&[focus_meta("gone", "New\u{202e} name")]);
        let o = origin(&b);
        assert_eq!(o.closed, Some(false));
        assert_eq!(o.focus_name.as_deref(), Some("New name"));
    }

    #[test]
    fn a_junk_claimed_tag_never_reaches_the_view() {
        let b = book();
        let mut jobs = vec![job("j", Some(claim("not a tag <script>", "sid")))];
        b.annotate(&mut jobs);
        let o = &jobs[0].nostromo.as_ref().unwrap().origin;
        assert_eq!(
            (o.kind, o.focus_tag.as_deref()),
            (OriginKind::Unverified, None)
        );
    }

    #[test]
    fn the_history_keeps_64_per_tag_and_ages_out_unseen_sessions() {
        let h = SessionHistory::in_memory();
        for i in 0..70 {
            h.record_at("t", &format!("s{i}"), 1_000 + i);
        }
        assert!(!h.contains("t", "s5") && h.contains("t", "s6") && h.contains("t", "s69"));
        h.record_at("t", "fresh", 1_000 + 91 * DAY_MS);
        assert!(h.contains("t", "fresh") && !h.contains("t", "s69"));
        // A session spawned again (a resume) is not aged out.
        h.record_at("long", "s", 0);
        h.record_at("long", "s", 80 * DAY_MS);
        h.record_at("other", "x", 100 * DAY_MS);
        assert!(h.contains("long", "s"));
    }

    #[test]
    fn the_history_and_the_book_survive_a_restart_with_private_files() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let hp = SessionHistory::path_beside(&dir.path().join("daemon-sessions.json"));
        let bp = OriginBook::path_beside(&dir.path().join("daemon-sessions.json"));
        {
            let h = SessionHistory::open(hp.clone());
            h.record("t", "sid");
            let b = OriginBook::open(bp.clone(), h, MotherAudit::disabled());
            b.stamp(
                "j",
                Stamp::focus(
                    "t",
                    Some("T"),
                    Some("sid"),
                    Via::Mcp,
                    Some(NotifyLevel::Off),
                ),
            );
        }
        for p in [&hp, &bp] {
            assert_eq!(
                std::fs::metadata(p).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        let h = SessionHistory::open(hp);
        assert!(h.contains("t", "sid"));
        let b = OriginBook::open(bp, h, MotherAudit::disabled());
        let e = b.entry("j").unwrap();
        assert_eq!(
            (e.kind, e.notify),
            (OriginKind::Focus, Some(NotifyLevel::Off))
        );
    }

    #[test]
    fn entries_absent_from_the_feed_for_30_days_are_pruned() {
        let b = book();
        b.stamp("old", Stamp::you(None));
        {
            let mut state = lock(&b.state);
            state.entries.get_mut("old").unwrap().last_seen_ms = now_ms() - 31 * DAY_MS;
        }
        b.stamp("recent", Stamp::you(None));
        b.annotate(&mut []);
        assert!(b.entry("old").is_none() && b.entry("recent").is_some());
    }

    #[test]
    fn the_probe_is_repeated_only_after_an_hour_of_no() {
        let t0 = Instant::now();
        assert!(reprobe_due(None, t0));
        assert!(!reprobe_due(Some((true, t0)), t0 + 10 * REPROBE_AFTER));
        assert!(!reprobe_due(Some((false, t0)), t0 + REPROBE_AFTER / 2));
        assert!(reprobe_due(Some((false, t0)), t0 + REPROBE_AFTER));
    }

    #[test]
    fn a_network_peer_loses_the_tag_and_session_and_a_sensitive_focus_its_names() {
        let mut a = JobAnnotation {
            origin: OriginView {
                kind: OriginKind::Focus,
                focus_tag: Some("fred-1".into()),
                name_snapshot: Some("Fred".into()),
                focus_name: Some("Fred".into()),
                closed: Some(false),
                session_prefix: Some("abcd1234".into()),
            },
            notify: Some(NotifyLevel::Wake),
            notice: Some(serde_json::json!({"status": "told"})),
            ..Default::default()
        };
        let mut plain = a.clone();
        plain.redact_for_network(|_| false);
        assert_eq!(plain.origin.focus_tag, None);
        assert_eq!(plain.origin.session_prefix, None);
        assert_eq!(plain.origin.focus_name.as_deref(), Some("Fred"));
        assert!(plain.notice.is_some());
        a.redact_for_network(|t| t == "fred-1");
        assert_eq!(a.origin.focus_name.as_deref(), Some(SENSITIVE_NAME));
        assert_eq!(a.origin.name_snapshot.as_deref(), Some(SENSITIVE_NAME));
        assert!(a.notice.is_none());
        assert_eq!(a.notify, Some(NotifyLevel::Wake));
    }

    // ── EnqueueGuard: a job whose enqueue has not answered is undecided ──────

    /// A book whose audit file is read back by the test.
    fn audited_book() -> (OriginBook, SessionHistory, PathBuf, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("audit").join("mother.jsonl");
        let history = SessionHistory::in_memory();
        let book = OriginBook::in_memory(history.clone(), MotherAudit::open(&path).unwrap());
        (book, history, path, dir)
    }

    fn audited(path: &Path, event: &str) -> usize {
        std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .filter(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()["event"] == event)
            .count()
    }

    fn annotation_of(book: &OriginBook, j: &MotherJob) -> JobAnnotation {
        let mut jobs = vec![j.clone()];
        book.annotate(&mut jobs);
        jobs.remove(0).nostromo.expect("annotated")
    }

    #[test]
    fn while_an_enqueue_is_in_flight_an_unstamped_job_is_undecided_and_leaves_no_entry_or_audit() {
        let (b, _history, audit, _dir) = audited_book();
        let forged = job("forged", Some(claim("claudia-1", "never-spawned")));
        let bare = job("bare", None);
        let guard = b.begin_enqueue();

        for j in [&forged, &bare] {
            for _ in 0..3 {
                assert_eq!(
                    annotation_of(&b, j),
                    JobAnnotation::default(),
                    "{}: shown without an origin",
                    j.id
                );
            }
            assert!(b.entry(&j.id).is_none(), "{}: not recorded", j.id);
        }
        assert_eq!(audited(&audit, "job_origin_unverified"), 0);

        // Once the enqueue is over the next poll decides them.
        drop(guard);
        let o = annotation_of(&b, &forged).origin;
        assert_eq!(
            (o.kind, o.focus_tag.as_deref()),
            (OriginKind::Unverified, Some("claudia-1"))
        );
        assert_eq!(annotation_of(&b, &bare).origin.kind, OriginKind::Unknown);
        assert_eq!(
            b.entry("forged").map(|e| e.kind),
            Some(OriginKind::Unverified)
        );
        assert_eq!(b.entry("bare").map(|e| e.kind), Some(OriginKind::Unknown));
        annotation_of(&b, &forged);
        assert_eq!(audited(&audit, "job_origin_unverified"), 1, "once, as ever");
    }

    #[test]
    fn a_job_is_decided_only_after_every_nested_enqueue_has_finished() {
        let (b, _history, audit, _dir) = audited_book();
        let forged = job("forged", Some(claim("claudia-1", "never-spawned")));
        let first = b.begin_enqueue();
        let second = b.clone().begin_enqueue();

        assert_eq!(annotation_of(&b, &forged), JobAnnotation::default());
        drop(first);
        assert_eq!(
            annotation_of(&b, &forged),
            JobAnnotation::default(),
            "one enqueue is still in flight"
        );
        assert!(b.entry("forged").is_none());
        drop(second);

        assert_eq!(
            annotation_of(&b, &forged).origin.kind,
            OriginKind::Unverified
        );
        assert_eq!(audited(&audit, "job_origin_unverified"), 1);
    }

    #[test]
    fn a_claim_the_history_vouches_for_is_recorded_even_while_an_enqueue_is_in_flight() {
        let (b, history, audit, _dir) = audited_book();
        history.record("claudia-1", "sid-aaaaaaaa-1");
        let _guard = b.begin_enqueue();

        let o = annotation_of(&b, &job("v", Some(claim("claudia-1", "sid-aaaaaaaa-1")))).origin;

        assert_eq!(
            (o.kind, o.focus_tag.as_deref()),
            (OriginKind::Focus, Some("claudia-1"))
        );
        assert_eq!(
            b.entry("v").map(|e| (e.kind, e.via)),
            Some((OriginKind::Focus, Via::Shell))
        );
        assert_eq!(audited(&audit, "job_origin_unverified"), 0);
    }

    #[test]
    fn a_stamped_job_shows_its_origin_while_another_enqueue_is_in_flight() {
        let (b, _history, _audit, _dir) = audited_book();
        assert!(b.stamp(
            "mine",
            Stamp::focus("claudia-1", Some("One"), None, Via::Mcp, None)
        ));
        let _guard = b.begin_enqueue();

        let o = annotation_of(&b, &job("mine", None)).origin;

        assert_eq!(
            (o.kind, o.focus_tag.as_deref()),
            (OriginKind::Focus, Some("claudia-1"))
        );
    }

    // ── tag_of ───────────────────────────────────────────────────────────────

    #[test]
    fn tag_of_names_the_one_focus_that_spawned_the_session() {
        let h = SessionHistory::in_memory();
        h.record("claudia-1", "sid-one");
        h.record("claudia-2", "sid-two");
        h.record("claudia-2", "sid-two-b");

        assert_eq!(h.tag_of("sid-one").as_deref(), Some("claudia-1"));
        assert_eq!(h.tag_of("sid-two-b").as_deref(), Some("claudia-2"));
    }

    #[test]
    fn tag_of_names_nobody_for_an_ambiguous_unknown_or_empty_session() {
        let h = SessionHistory::in_memory();
        h.record("claudia-1", "shared");
        h.record("claudia-2", "shared");
        h.record("claudia-1", "mine");

        assert_eq!(h.tag_of("shared"), None, "two focuses have it");
        assert_eq!(h.tag_of("never-spawned"), None);
        assert_eq!(h.tag_of(""), None);
        h.record("claudia-3", "");
        assert_eq!(h.tag_of(""), None, "an empty id is never in the history");
        assert_eq!(h.tag_of("mine").as_deref(), Some("claudia-1"));
    }

    // ── probe_help ───────────────────────────────────────────────────────────

    fn script(dir: &Path, name: &str, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    /// Is `pid` a live process? A zombie (killed, not reaped yet) is not.
    fn is_running(pid: u32) -> bool {
        if Path::new("/proc/self/stat").exists() {
            return match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
                Ok(stat) => !matches!(
                    stat.rsplit(')')
                        .next()
                        .and_then(|rest| rest.trim_start().chars().next()),
                    Some('Z' | 'X')
                ),
                Err(_) => false,
            };
        }
        let out = std::process::Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
            .unwrap();
        let state = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        !state.is_empty() && !state.starts_with('Z')
    }

    #[tokio::test]
    async fn a_mother_that_hangs_on_help_is_answered_no_at_the_limit_and_the_process_is_killed() {
        let dir = tempfile::tempdir().unwrap();
        let pid_file = dir.path().join("pid");
        let mother = script(
            dir.path(),
            "mother",
            &format!("echo $$ > '{}'\nexec sleep 30", pid_file.display()),
        );
        let started = Instant::now();

        let supported = probe_help(
            super::super::mother_command_at(&mother),
            Duration::from_millis(500),
        )
        .await;

        assert!(!supported, "a probe that timed out is a no");
        assert!(
            started.elapsed() < Duration::from_secs(20),
            "the probe returned at its limit, not when the child finished: {:?}",
            started.elapsed()
        );
        let pid: u32 = std::fs::read_to_string(&pid_file)
            .expect("the fake mother started")
            .trim()
            .parse()
            .expect("a pid");
        let deadline = Instant::now() + Duration::from_secs(20);
        while is_running(pid) {
            assert!(
                Instant::now() < deadline,
                "the hung `mother` (pid {pid}) is still running after the probe gave up"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    #[tokio::test]
    async fn the_probe_says_yes_only_when_add_help_names_the_origin_focus_flag() {
        let dir = tempfile::tempdir().unwrap();
        let named = script(
            dir.path(),
            "named",
            "echo 'usage: mother add --plan-file PATH [--origin-session SID] [--origin-focus TAG]'",
        );
        let old = script(
            dir.path(),
            "old",
            "echo 'add: unknown flag: --help' >&2\nexit 2",
        );
        let session_only = script(
            dir.path(),
            "session-only",
            "echo 'usage: mother add --plan-file PATH [--origin-session SID]'",
        );
        let limit = Duration::from_secs(20);

        assert!(probe_help(super::super::mother_command_at(&named), limit).await);
        assert!(!probe_help(super::super::mother_command_at(&old), limit).await);
        assert!(
            !probe_help(super::super::mother_command_at(&session_only), limit).await,
            "--origin-session is not --origin-focus"
        );
        assert!(
            !probe_help(
                super::super::mother_command_at(dir.path().join("no-such-mother")),
                limit
            )
            .await,
            "a mother that cannot start is a no"
        );
    }
}
